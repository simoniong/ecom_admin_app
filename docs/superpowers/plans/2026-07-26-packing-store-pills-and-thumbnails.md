# 打包列表店鋪 pill 與 SKU 縮圖 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 打包列表的店鋪篩選改為頁面內的 pill（走 URL 參數、不碰 session），移除列表的店鋪欄，並讓每個 SKU 顯示縮圖、hover 時彈出約 400px 的大圖。

**Architecture:** 店鋪範圍改由 `PackagesController#selected_store` 從 `params[:store]` 解析，取代目前四處散落的 `current_shopify_store`；`packages` 同時退出 `STORE_SWITCHER_CONTROLLERS`，頂部下拉不再渲染也不再寫 session。縮圖走 `package_item → product_variant → product.image_url`，經一個把尺寸插進 Shopify CDN 檔名的 helper 縮小，hover 大圖由 Stimulus controller 掛到 `document.body` 以繞開表格的 `overflow-x-auto` 裁切。

**Tech Stack:** Rails 8.1、PostgreSQL（UUID 主鍵）、Hotwire（Turbo + Stimulus）、Importmap（無 JS build step）、Propshaft、Tailwind CSS、RSpec + FactoryBot。

**Spec:** `docs/superpowers/specs/2026-07-26-packing-store-pills-and-thumbnails-design.md`

## Global Constraints

- **絕不直接 commit 到 `main` 或 `staging`。** 本計畫在 `feature/packing-store-pills-and-thumbnails` 分支上執行。
- **工作目錄**：`/opt/dev/ecom_admin_app/.claude/worktrees/split-ux`。所有指令都在此執行，不要 `cd` 回主 checkout。
- **參數名必須是 `store`，不能是 `store_id`。** `AdminController` 的 `before_action :persist_store_selection`（`admin_controller.rb:5`）看到 `params[:store_id]` 就會寫進 `session[:store_id]`，沿用該名稱會讓「不碰 session」這個目標從一開始就不成立。
- **不改其他頁面的店鋪切換機制。** dashboard / orders / shipments / tickets / ad_campaigns 的行為完全不動。
- **測試：RSpec + FactoryBot，不使用 fixtures。** 需維持 95%+ 行覆蓋率。測試必須打真實資料庫。
- **RuboCop Omakase**：`bin/rubocop` 必須乾淨。本專案的陣列字面值內側留空格（`[ "a", "b" ]`）。注意：在此 worktree 內執行 `bin/rubocop` 會誤報約 286 個 `db/schema.rb` 的 offenses（設定的排除規則在 worktree 的點路徑下比對不到），那些不是真的，只檢查你改過的檔案。
- **i18n 三個語系必須同步**：`config/locales/zh-TW.yml`、`config/locales/zh-CN.yml`、`config/locales/en.yml`。
- **系統測試前** `app/assets/builds/tailwind.css` 必須存在，否則 Tailwind 的 `hidden` 失效會造成大量假失敗。不存在就先跑 `bin/rails tailwindcss:build`。
- **每個任務結束時 commit**，訊息結尾加上：
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```

## File Structure

**新增**

- `app/javascript/controllers/image_preview_controller.js` — 唯一職責：hover 時把大圖預覽層掛到 `document.body` 並定位，離開時移除。
- `spec/helpers/packages_helper_spec.rb`

**修改**

- `app/controllers/admin_controller.rb:28` — `STORE_SWITCHER_CONTROLLERS` 移除 `packages`。
- `app/controllers/packages_controller.rb` — 新增 `selected_store`；`index` 的 eager load；`sync` 與 `scoped_packages` 改用 `selected_store`。
- `app/helpers/packages_helper.rb` — 新增 `shopify_image_variant`。
- `app/views/packages/_filter_bar.html.erb` — 店鋪 pill 那一行。
- `app/views/packages/index.html.erb` — 移除店鋪 `<th>`、調整 colspan、傳 stores 給 filter bar。
- `app/views/packages/_package_row.html.erb` — 移除店鋪 `<td>`、時區條件改用 `selected_store`、SKU 縮圖。
- `config/locales/{zh-TW,zh-CN,en}.yml`
- `spec/requests/packages_spec.rb`、`spec/system/packages_spec.rb`

---

### Task 1: `shopify_image_variant` helper

列表最多 50 列、每列數個 SKU，直接引用 Shopify 原圖是數十 MB 的下載。Shopify CDN 的慣例是在副檔名前插入尺寸。這個 helper 只做這件事。

**Files:**
- Modify: `app/helpers/packages_helper.rb`
- Test: `spec/helpers/packages_helper_spec.rb`（新增檔案）

**Interfaces:**
- Consumes: 無（本計畫第一個任務）。
- Produces: `PackagesHelper#shopify_image_variant(url, size)` —— `url` 是 `String` 或 `nil`，`size` 是像 `"100x100"` 的 `String`。回傳插入尺寸後的 `String`；`url` 為 nil/空白時回傳 `nil`；URL 不符合可辨識格式時原樣回傳。Task 4 用它產生縮圖（`"100x100"`）與大圖（`"400x400"`）。

- [ ] **Step 1: 寫失敗的測試**

Create `spec/helpers/packages_helper_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe PackagesHelper, type: :helper do
  describe "#shopify_image_variant" do
    it "inserts the size before the extension" do
      url = "https://cdn.shopify.com/s/files/1/0033/4807/products/painting.jpg"

      expect(helper.shopify_image_variant(url, "100x100"))
        .to eq("https://cdn.shopify.com/s/files/1/0033/4807/products/painting_100x100.jpg")
    end

    # ?v= is Shopify's cache buster. Dropping it serves a stale image after the
    # merchant replaces the picture, so the query string has to survive.
    it "keeps the query string" do
      url = "https://cdn.shopify.com/s/files/1/0033/painting.jpg?v=1699999999"

      expect(helper.shopify_image_variant(url, "400x400"))
        .to eq("https://cdn.shopify.com/s/files/1/0033/painting_400x400.jpg?v=1699999999")
    end

    it "handles an uppercase extension" do
      url = "https://cdn.shopify.com/s/files/1/0033/PAINTING.JPG"

      expect(helper.shopify_image_variant(url, "100x100"))
        .to eq("https://cdn.shopify.com/s/files/1/0033/PAINTING_100x100.JPG")
    end

    it "handles the other formats Shopify serves" do
      %w[png webp gif jpeg].each do |ext|
        url = "https://cdn.shopify.com/s/files/1/art.#{ext}"

        expect(helper.shopify_image_variant(url, "100x100"))
          .to eq("https://cdn.shopify.com/s/files/1/art_100x100.#{ext}")
      end
    end

    # Guessing at an unrecognized URL shape produces a broken link — a missing
    # image. Returning the original produces a slow image. Slow beats missing.
    it "returns a URL with no recognizable extension untouched" do
      url = "https://example.com/images/12345"

      expect(helper.shopify_image_variant(url, "100x100")).to eq(url)
    end

    it "does not treat a dot in the path as an extension" do
      url = "https://cdn.example.com/v1.2/image"

      expect(helper.shopify_image_variant(url, "100x100")).to eq(url)
    end

    it "returns nil for nil" do
      expect(helper.shopify_image_variant(nil, "100x100")).to be_nil
    end

    it "returns nil for a blank string" do
      expect(helper.shopify_image_variant("   ", "100x100")).to be_nil
    end
  end
end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/helpers/packages_helper_spec.rb`
Expected: FAIL，`undefined method 'shopify_image_variant'`。

- [ ] **Step 3: 實作 helper**

在 `app/helpers/packages_helper.rb` 的 `packages_list_path` 方法之後加入：

```ruby
  # Shopify's CDN serves a resized copy when the dimensions are spliced into the
  # filename: painting.jpg -> painting_100x100.jpg. The packing list renders up
  # to 50 rows of several SKUs each, so linking the originals would be tens of
  # megabytes per page.
  #
  # An unrecognized URL shape is returned UNCHANGED rather than guessed at: the
  # cost of being wrong here is a broken link (no image at all), while the cost
  # of not transforming is a slow image. Slow beats missing.
  IMAGE_EXTENSIONS = %w[jpg jpeg png webp gif].freeze

  def shopify_image_variant(url, size)
    return nil if url.blank?

    # Split the query off first — ?v= is Shopify's cache buster and must survive.
    path, _, query = url.to_s.partition("?")
    extension = File.extname(path).delete_prefix(".")
    return url unless IMAGE_EXTENSIONS.include?(extension.downcase)

    resized = "#{path.delete_suffix(".#{extension}")}_#{size}.#{extension}"
    query.present? ? "#{resized}?#{query}" : resized
  end
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/helpers/packages_helper_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 5: Lint**

Run: `bin/rubocop app/helpers/packages_helper.rb spec/helpers/packages_helper_spec.rb`
Expected: no offenses。

- [ ] **Step 6: Commit**

```bash
git add app/helpers/packages_helper.rb spec/helpers/packages_helper_spec.rb
git commit -m "$(cat <<'EOF'
feat(packing): add shopify_image_variant for CDN-resized images

Splices dimensions into a Shopify CDN filename so the packing list can show
thumbnails without downloading full-size originals. An unrecognized URL is
returned unchanged — a slow image beats a broken one.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: 店鋪範圍改由 URL 參數決定

**Files:**
- Modify: `app/controllers/admin_controller.rb:28`
- Modify: `app/controllers/packages_controller.rb`（`sync` 約第 48 行、`scoped_packages` 約第 569 行、私有區塊）
- Test: `spec/requests/packages_spec.rb`

**Interfaces:**
- Consumes: 無。
- Produces: `PackagesController#selected_store` → `ShopifyStore` 或 `nil`（`nil` 表示「全部可見店鋪」）。宣告為 `helper_method`，Task 3 的 filter bar 與 Task 4 的 row partial 都會用它。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/requests/packages_spec.rb` 的 `describe "GET /packages" do` 區塊內加入：

```ruby
    describe "store filter" do
      let(:other_store) { create(:shopify_store, user: user, company: company) }
      let(:other_customer) { create(:customer, shopify_store: other_store) }

      let!(:other_store_package) do
        order = create(:order, customer: other_customer, shopify_store: other_store, name: "PKS#7701")
        create(:package, shopify_store: other_store, order: order, aasm_state: "pending_review", number: 77)
      end

      it "lists every visible store by default" do
        get packages_path

        expect(response.body).to include("PKS#1001")
        expect(response.body).to include("PKS#7701")
      end

      it "narrows to the store named by the store param" do
        get packages_path, params: { store: other_store.id }

        expect(response.body).to include("PKS#7701")
        expect(response.body).not_to include("PKS#1001")
      end

      it "falls back to every store for an unknown store id" do
        get packages_path, params: { store: SecureRandom.uuid }

        expect(response.body).to include("PKS#1001")
        expect(response.body).to include("PKS#7701")
      end

      it "ignores a store belonging to another company" do
        foreign_user = create(:user)
        foreign_store = create(:shopify_store, user: foreign_user, company: foreign_user.companies.first)

        get packages_path, params: { store: foreign_store.id }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("PKS#1001")
        expect(response.body).to include("PKS#7701")
      end

      # The whole point of moving off the global switcher: selecting a store here
      # must not follow the user to the orders page.
      it "does not write the selection into the session" do
        get packages_path, params: { store: other_store.id }

        expect(session[:store_id]).to be_nil
      end
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/requests/packages_spec.rb -e "store filter"`
Expected: FAIL —— `narrows to the store named by the store param` 失敗，因為 `store` 參數目前完全沒有被讀取，列表仍包含兩間店鋪的資料。

- [ ] **Step 3: 打包頁退出全域切換器**

`app/controllers/admin_controller.rb` 第 28 行：

```ruby
  STORE_SWITCHER_CONTROLLERS = %w[dashboard orders shipments tickets ad_campaigns packages].freeze
```

換成：

```ruby
  # packages is deliberately absent: the packing list owns its own store filter
  # (a URL param, rendered as pills in its filter bar). Listing it here would
  # both render a second, competing control and let persist_store_selection
  # write the choice into the shared session[:store_id], which is exactly what
  # that filter exists to avoid.
  STORE_SWITCHER_CONTROLLERS = %w[dashboard orders shipments tickets ad_campaigns].freeze
```

`STORE_ALL_ALLOWED_CONTROLLERS`（第 29 行）保持不變 —— 它現在對 packages 不再有作用，但移除它是另一條路徑的行為改動，不在本次範圍。

- [ ] **Step 4: 新增 `selected_store` 並替換用到 `current_shopify_store` 的兩處 controller 程式碼**

在 `app/controllers/packages_controller.rb` 的私有區塊、`scoped_packages` 方法之前加入：

```ruby
  # The packing list's own store filter. Unlike current_shopify_store this reads
  # ONLY the URL — nothing is persisted, so choosing a store here cannot follow
  # the user to another page (see AdminController#persist_store_selection, which
  # no longer fires for this controller).
  #
  # nil means "every visible store". An unknown id, or one belonging to another
  # company, resolves to nil rather than 404ing: visible_shopify_stores is the
  # isolation boundary, so a foreign id simply finds nothing.
  def selected_store
    return @selected_store if defined?(@selected_store)

    @selected_store = visible_shopify_stores.find_by(id: params[:store])
  end
  helper_method :selected_store
```

把 `scoped_packages` 改成：

```ruby
  def scoped_packages
    store_ids = selected_store ? [ selected_store.id ] : visible_shopify_stores.select(:id)
    Package.where(shopify_store_id: store_ids)
  end
```

並更新它上方的註解，把提到 store switcher 的部分換成：

```ruby
  # Scoped to the store chosen in the list's own store filter (params[:store])
  # when one is chosen, else to every store the membership can see. Either way
  # the ids come from visible_shopify_stores, so cross-company/cross-group
  # isolation holds.
```

`sync` 動作（約第 48 行）：

```ruby
    stores = current_shopify_store ? [ current_shopify_store ] : visible_shopify_stores
```

換成：

```ruby
    stores = selected_store ? [ selected_store ] : visible_shopify_stores
```

- [ ] **Step 5: 執行測試確認通過**

Run: `bundle exec rspec spec/requests/packages_spec.rb`
Expected: PASS，0 failures。

既有範例若因為打包頁不再有全域切換器而失敗（例如斷言 `store_id` 參數會收斂列表、或斷言頁面上有 store-switcher 元素），改用新的 `store` 參數／移除該斷言，並在報告中列出你改了哪些、為什麼。不要為了讓舊測試通過而把 `packages` 加回 `STORE_SWITCHER_CONTROLLERS`。

- [ ] **Step 6: 執行系統測試確認沒有回歸**

Run: `bundle exec rspec spec/system/packages_spec.rb`
Expected: PASS，0 failures。若 `app/assets/builds/tailwind.css` 不存在請先跑 `bin/rails tailwindcss:build`。

- [ ] **Step 7: Lint**

Run: `bin/rubocop app/controllers/admin_controller.rb app/controllers/packages_controller.rb spec/requests/packages_spec.rb`
Expected: no offenses。

- [ ] **Step 8: Commit**

```bash
git add app/controllers spec/requests/packages_spec.rb
git commit -m "$(cat <<'EOF'
feat(packing): scope the packing list by a URL store param

The list now reads params[:store] instead of the session-backed global
switcher, so choosing a store here no longer changes what the orders page
shows. packages leaves STORE_SWITCHER_CONTROLLERS so only one control remains.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: 店鋪 pill 與移除店鋪欄

**Files:**
- Modify: `app/views/packages/_filter_bar.html.erb`
- Modify: `app/views/packages/index.html.erb`（表頭、colspan、render 呼叫）
- Modify: `app/views/packages/_package_row.html.erb`（移除店鋪 `<td>`、時區條件）
- Modify: `config/locales/{zh-TW,zh-CN,en}.yml`
- Test: `spec/requests/packages_spec.rb`、`spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: Task 2 的 `selected_store`（helper_method，view 可直接呼叫）；既有的 `packages_list_path(overrides)` helper（保留當前查詢參數、覆寫指定項，`nil` 值會移除該參數）。
- Produces: i18n key `packages.filters.store`。表格欄數由 9 減為 8（不含 bulk 勾選欄）。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/requests/packages_spec.rb` 的 `describe "store filter"` 區塊內加入：

```ruby
      it "renders a pill for every visible store" do
        get packages_path

        expect(response.body).to include(I18n.t("packages.filters.store"))
        expect(response.body).to include(store.display_name)
        expect(response.body).to include(other_store.display_name)
      end

      it "drops the store column from the table" do
        get packages_path

        expect(response.body).not_to include(I18n.t("packages.columns.store"))
      end

      it "keeps the header and body cell counts in agreement" do
        get packages_path

        doc = Nokogiri::HTML(response.body)
        header_cells = doc.css("thead th").size
        body_cells = doc.css("tbody tr").first.css("td").size

        expect(body_cells).to eq(header_cells)
      end
```

在同一個檔案的 `describe "GET /packages"` 內、`describe "store filter"` 之外加入（`store` 是該 spec 檔頂層唯一的可見店鋪，所以這裡不需要第二間）：

```ruby
    it "hides the store filter row when only one store is visible" do
      get packages_path

      expect(response.body).not_to include(I18n.t("packages.filters.store"))
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/requests/packages_spec.rb -e "renders a pill for every visible store"`
Expected: FAIL —— `packages.filters.store` 這個 i18n key 還不存在，`I18n.t` 回傳 translation-missing 字串，斷言不成立。

- [ ] **Step 3: 新增 i18n**

`config/locales/zh-TW.yml` 的 `packages.filters` 底下（`country:` 那一行旁）加入：

```yaml
      store: "店鋪"
```

`config/locales/zh-CN.yml` 的 `packages.filters` 底下加入：

```yaml
      store: "店铺"
```

`config/locales/en.yml` 的 `packages.filters` 底下加入：

```yaml
      store: "Store"
```

- [ ] **Step 4: filter bar 加入店鋪 pill**

`app/views/packages/_filter_bar.html.erb`，在最外層 `<div class="bg-white ...">` 之後、國家那一段 `<% if countries.any? %>` **之前**插入：

```erb
  <%# Only worth a row when there is a choice to make — a filter with one
      permanent option is noise. %>
  <% if stores.size > 1 %>
    <%# data-testid because "全部" is shared copy with the country row — tests
        need to say WHICH row's 全部 they mean. %>
    <div data-testid="store-filter" class="flex items-start gap-3">
      <span class="shrink-0 pt-1 text-sm text-gray-500"><%= t("packages.filters.store") %></span>
      <div class="flex flex-wrap gap-1.5">
        <%= link_to t("packages.filters.all"), packages_list_path(store: nil, page: nil),
              class: "px-2.5 py-1 text-sm rounded #{selected_store.nil? ? 'bg-blue-600 text-white' : 'text-gray-700 hover:bg-gray-100'}" %>
        <% stores.each do |store| %>
          <%= link_to store.display_name, packages_list_path(store: store.id, page: nil),
                class: "px-2.5 py-1 text-sm rounded #{selected_store&.id == store.id ? 'bg-blue-600 text-white' : 'text-gray-700 hover:bg-gray-100'}" %>
        <% end %>
      </div>
    </div>
  <% end %>
```

並把該檔開頭的註解第一句改為：

```erb
<%# 店鋪 + 國家區域 + 排序方式。三者都是純連結（Turbo Drive 負責導覽），不需要
    Stimulus。國家清單只列出這個狀態下實際存在的國家，所以不會出現點了沒有結果
    的膠囊。 %>
```

- [ ] **Step 5: index 傳入 stores 並移除店鋪欄**

`app/views/packages/index.html.erb`，找到 filter bar 的 render 呼叫：

```erb
  <%= render "packages/filter_bar", countries: @countries, country: @country,
        sort_column: @sort_column, sort_direction: @sort_direction %>
```

換成：

```erb
  <%= render "packages/filter_bar", countries: @countries, country: @country,
        sort_column: @sort_column, sort_direction: @sort_direction,
        stores: visible_shopify_stores.to_a %>
```

移除表頭的店鋪欄——刪掉這三行：

```erb
              <% unless current_shopify_store %>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase"><%= t("packages.columns.store") %></th>
              <% end %>
```

空狀態的 colspan 從：

```erb
                <td colspan="<%= 8 + (bulk ? 1 : 0) + (current_shopify_store ? 0 : 1) %>" class="px-4 py-8 text-center text-sm text-gray-500"><%= t("packages.no_packages") %></td>
```

改為（店鋪欄消失後固定 8 欄，只剩 bulk 勾選欄是變數）：

```erb
                <td colspan="<%= 8 + (bulk ? 1 : 0) %>" class="px-4 py-8 text-center text-sm text-gray-500"><%= t("packages.no_packages") %></td>
```

- [ ] **Step 6: row partial 移除店鋪欄、時區條件改用 `selected_store`**

`app/views/packages/_package_row.html.erb`，刪掉店鋪 `<td>` 那一段（約第 8-12 行）：

```erb
  <%# Only rendered in the all-stores view — in single-store mode the column
      would repeat the same name on every row for no information. %>
  <% unless current_shopify_store %>
    <td class="px-4 py-3 text-sm text-gray-700 align-top whitespace-nowrap"><%= package.shopify_store.display_name %></td>
  <% end %>
```

再找到時區旗標那一行：

```erb
  <% show_zone = current_shopify_store.nil? %>
```

換成：

```erb
  <%# Same rule as before, now driven by the list's own store filter: in the
      all-stores view different stores render different local times against an
      absolute-time sort, and the abbreviation is what explains that. %>
  <% show_zone = selected_store.nil? %>
```

- [ ] **Step 7: 加入系統測試**

在 `spec/system/packages_spec.rb` 檔案結尾的最後一個 `end` 之前加入：

```ruby
  describe "店鋪篩選" do
    let(:second_store) { create(:shopify_store, user: user, company: company) }
    let(:second_customer) { create(:customer, shopify_store: second_store) }

    let!(:second_store_package) do
      order = create(:order, customer: second_customer, shopify_store: second_store, name: "PKS#8801")
      create(:package, shopify_store: second_store, order: order, aasm_state: "pending_review", number: 88)
    end

    it "narrows to one store and back to all" do
      visit packages_path(state: "pending_review")

      expect(page).to have_content("PKS#3001")
      expect(page).to have_content("PKS#8801")

      within("[data-testid='store-filter']") { click_link second_store.display_name }
      expect(page).to have_content("PKS#8801")
      expect(page).to have_no_content("PKS#3001")

      # Scoped because "全部" is shared copy with the country row — an unscoped
      # click_link matches both and Capybara raises Ambiguous.
      within("[data-testid='store-filter']") { click_link I18n.t("packages.filters.all") }
      expect(page).to have_content("PKS#3001")
    end
  end
```

- [ ] **Step 8: 執行測試確認通過**

Run: `bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 9: Commit**

```bash
git add app/views/packages config/locales spec
git commit -m "$(cat <<'EOF'
feat(packing): add store pills and drop the store column

The store filter now sits in the list's own filter bar as pills, alongside
country and sort. The per-row store column goes away with it — the pills show
what is in view, and the column cost horizontal space on every row.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: SKU 縮圖與 hover 大圖

**Files:**
- Create: `app/javascript/controllers/image_preview_controller.js`
- Modify: `app/controllers/packages_controller.rb`（`index` 的 eager load，約第 40 行）
- Modify: `app/views/packages/_package_row.html.erb`（商品欄）
- Test: `spec/requests/packages_spec.rb`、`spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: Task 1 的 `shopify_image_variant(url, size)`。
- Produces: Stimulus controller `image-preview`（Stimulus 依檔名自動註冊，`app/javascript/controllers` 已由 `pin_all_from` 收錄，不需要改 importmap）。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/requests/packages_spec.rb` 的 `describe "GET /packages"` 區塊內加入：

```ruby
    describe "SKU thumbnails" do
      let(:product) do
        create(:product, shopify_store: store,
               image_url: "https://cdn.shopify.com/s/files/1/art.jpg?v=42")
      end
      let(:variant) { create(:product_variant, product: product, sku: "ART-1") }

      it "renders a CDN-resized thumbnail for an item with a product image" do
        create(:package_item, package: review_package, product_variant: variant, sku: "ART-1", quantity: 1)

        get packages_path

        expect(response.body).to include("https://cdn.shopify.com/s/files/1/art_100x100.jpg?v=42")
      end

      it "exposes the larger preview url for the hover controller" do
        create(:package_item, package: review_package, product_variant: variant, sku: "ART-1", quantity: 1)

        get packages_path

        expect(response.body).to include("https://cdn.shopify.com/s/files/1/art_400x400.jpg?v=42")
      end

      it "renders a placeholder for an item with no product variant" do
        create(:package_item, package: review_package, product_variant: nil, sku: "NOVARIANT", quantity: 1)

        get packages_path

        expect(response.body).to include("data-testid=\"sku-thumb-placeholder\"")
      end

      it "renders a placeholder when the product has no image" do
        imageless = create(:product, shopify_store: store, image_url: nil)
        imageless_variant = create(:product_variant, product: imageless, sku: "NOIMG")
        create(:package_item, package: review_package, product_variant: imageless_variant, sku: "NOIMG", quantity: 1)

        get packages_path

        expect(response.body).to include("data-testid=\"sku-thumb-placeholder\"")
      end
    end
```

`:product` 與 `:product_variant` factory 都已存在且屬性名稱相符（`spec/factories/products.rb` 的 `image_url` 預設為 `nil`，正好是上面「產品沒有圖」那個案例要的），可直接使用，不需要新增或調整 factory。

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/requests/packages_spec.rb -e "SKU thumbnails"`
Expected: FAIL —— 商品欄目前只渲染文字，找不到任何圖片 URL 或佔位方塊。

- [ ] **Step 3: eager load 商品與圖片**

`app/controllers/packages_controller.rb` 的 `index`：

```ruby
    @packages = filtered.includes(:order, :package_items, :shopify_store, :logistics_channel)
```

換成：

```ruby
    # package_items -> product_variant -> product is what the SKU thumbnails
    # read; without it each SKU costs two more queries and a 50-row page turns
    # into hundreds.
    @packages = filtered.includes(:order, :shopify_store, :logistics_channel,
                                  package_items: { product_variant: :product })
```

- [ ] **Step 4: row partial 加入縮圖**

`app/views/packages/_package_row.html.erb`，找到商品欄裡的這一段：

```erb
        <div class="whitespace-nowrap">
          <span class="font-mono text-xs text-gray-500"><%= item.sku.presence || "—" %></span>
```

把 `<div class="whitespace-nowrap">` 整個區塊的開頭換成（保留該 div 內原有的 SKU / 數量 / 標題 / 退款標籤不動，只是包進一個 flex 容器並在前面加上縮圖）：

```erb
        <% image_url = item.product_variant&.product&.image_url %>
        <div class="flex items-center gap-2 whitespace-nowrap">
          <% if image_url.present? %>
            <%# The preview is mounted on document.body by the controller: this
                table sits inside overflow-x-auto, which would clip an absolutely
                positioned popover. %>
            <img src="<%= shopify_image_variant(image_url, "100x100") %>"
                 data-controller="image-preview"
                 data-action="mouseenter->image-preview#show mouseleave->image-preview#hide"
                 data-image-preview-url-value="<%= shopify_image_variant(image_url, "400x400") %>"
                 alt="" loading="lazy"
                 class="w-12 h-12 shrink-0 rounded object-cover border border-gray-200 bg-gray-50">
          <% else %>
            <div data-testid="sku-thumb-placeholder"
                 class="w-12 h-12 shrink-0 rounded border border-gray-200 bg-gray-100"></div>
          <% end %>
          <div>
            <span class="font-mono text-xs text-gray-500"><%= item.sku.presence || "—" %></span>
```

並在該 div 原本的收尾處補上一層 `</div>`，讓新加的內層 `<div>` 正確閉合。原本是：

```erb
        </div>
      <% end %>
```

改為：

```erb
          </div>
        </div>
      <% end %>
```

- [ ] **Step 5: 建立 hover 預覽 controller**

Create `app/javascript/controllers/image_preview_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Hover preview for the packing list's SKU thumbnails.
//
// The popover is appended to document.body rather than next to the thumbnail
// because the list's table sits inside an overflow-x-auto container, which
// clips any absolutely positioned child. A fixed-position node on body escapes
// that clipping entirely.
//
// One node is reused for the whole page — a preview per thumbnail would leave
// dozens of hidden 400px images in the DOM.
export default class extends Controller {
  static values = { url: String }

  static PREVIEW_ID = "sku-image-preview"
  static SIZE = 400
  static GAP = 16

  show() {
    if (!this.urlValue) return

    const preview = this.#node()
    preview.src = this.urlValue
    preview.style.display = "block"
    this.#position(preview)
  }

  hide() {
    const preview = document.getElementById(this.constructor.PREVIEW_ID)
    if (preview) preview.style.display = "none"
  }

  // Leaving the page with a preview open would strand it on body.
  disconnect() {
    this.hide()
  }

  #node() {
    let preview = document.getElementById(this.constructor.PREVIEW_ID)
    if (preview) return preview

    preview = document.createElement("img")
    preview.id = this.constructor.PREVIEW_ID
    preview.alt = ""
    preview.style.position = "fixed"
    preview.style.zIndex = "60"
    preview.style.width = `${this.constructor.SIZE}px`
    preview.style.height = `${this.constructor.SIZE}px`
    preview.style.objectFit = "contain"
    preview.style.pointerEvents = "none"
    preview.style.background = "#fff"
    preview.style.border = "1px solid #e5e7eb"
    preview.style.borderRadius = "8px"
    preview.style.boxShadow = "0 10px 25px rgba(0,0,0,0.15)"
    document.body.appendChild(preview)
    return preview
  }

  // Prefer the right of the thumbnail, flip left when that would overflow the
  // viewport, and clamp vertically so the preview is never half off-screen.
  #position(preview) {
    const anchor = this.element.getBoundingClientRect()
    const size = this.constructor.SIZE
    const gap = this.constructor.GAP

    let left = anchor.right + gap
    if (left + size > window.innerWidth) left = anchor.left - size - gap
    if (left < gap) left = gap

    let top = anchor.top + anchor.height / 2 - size / 2
    if (top < gap) top = gap
    if (top + size > window.innerHeight - gap) top = window.innerHeight - size - gap

    preview.style.left = `${left}px`
    preview.style.top = `${top}px`
  }
}
```

- [ ] **Step 6: 加入系統測試**

在 `spec/system/packages_spec.rb` 檔案結尾的最後一個 `end` 之前加入：

```ruby
  describe "SKU 縮圖 hover" do
    let(:product) do
      create(:product, shopify_store: store,
             image_url: "https://cdn.shopify.com/s/files/1/art.jpg?v=42")
    end
    let(:variant) { create(:product_variant, product: product, sku: "ART-1") }

    before do
      create(:package_item, package: review_package, product_variant: variant, sku: "ART-1", quantity: 1)
    end

    it "shows the large preview on hover, mounted outside the scrolling table" do
      visit packages_path(state: "pending_review")

      expect(page).to have_no_css("#sku-image-preview")

      find("img[data-controller='image-preview']").hover

      expect(page).to have_css("#sku-image-preview", visible: :visible)

      # The whole reason the controller mounts on body: an absolutely positioned
      # popover inside the table would be clipped by its overflow-x-auto wrapper.
      parent_tag = page.evaluate_script(
        "document.getElementById('sku-image-preview').parentElement.tagName"
      )
      expect(parent_tag).to eq("BODY")
    end
  end
```

- [ ] **Step 7: 執行測試確認通過**

Run: `bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb spec/helpers/packages_helper_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 8: 全套件驗證**

Run: `bundle exec rspec`
Expected: PASS，0 failures，行覆蓋率 ≥ 95%。若覆蓋率未達標，找出未覆蓋的新程式碼並補測試——不要調低門檻。

- [ ] **Step 9: 完整 CI 檢查**

Run: `bin/rubocop && bin/brakeman --no-pager && bin/bundler-audit && bin/importmap audit`
Expected: rubocop 在你改過的檔案上乾淨（`db/schema.rb` 的誤報忽略），其餘全部乾淨。

- [ ] **Step 10: Commit**

```bash
git add app/javascript app/controllers/packages_controller.rb app/views/packages/_package_row.html.erb spec
git commit -m "$(cat <<'EOF'
feat(packing): show SKU thumbnails with a hover preview

Each SKU renders a CDN-resized thumbnail; hovering mounts a 400px preview on
document.body, which is what keeps it out of the table's overflow-x-auto
clipping. Items with no variant or no product image get a placeholder so row
heights stay even.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## 完成後

全部任務完成、`bundle exec rspec` 全綠、CI 檢查乾淨後，使用 `superpowers:finishing-a-development-branch` skill 決定如何整合（本專案流程為：feature branch → PR 到 `staging`）。
