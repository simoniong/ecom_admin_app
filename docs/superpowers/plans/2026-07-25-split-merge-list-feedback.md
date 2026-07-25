# 折包／合併列表即時回饋 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 折包／合併成功後自動關閉 modal、列表就地更新並短暫高亮受影響的列，且已折包的包裹在列表上帶「折 1/3」標記。

**Architecture:** 列表的 `<tr>` 加上 `dom_id` 讓 Turbo Stream 能指名替換。新增自訂 Turbo Stream action `dismiss_modal` 讓伺服器回應能關閉 modal。折包／合併的 turbo_stream 樣板改為同時關 modal 與就地重寫受影響的列。箱號標記的資料由新的 `PackageSiblingIndex` 服務一次查詢供應，取代逐列 COUNT。

**Tech Stack:** Rails 8.1、PostgreSQL（UUID 主鍵）、Hotwire（Turbo Streams + Stimulus）、Importmap（無 JS build step）、Propshaft、Tailwind CSS、RSpec + FactoryBot、AASM。

**Spec:** `docs/superpowers/specs/2026-07-25-split-merge-list-feedback-design.md`

## Global Constraints

- **絕不直接 commit 到 `main` 或 `staging`。** 本計畫在 `feature/packing-split-ux` 分支上執行。
- **工作目錄**：`/opt/dev/ecom_admin_app/.claude/worktrees/split-ux`。所有指令都在此執行，不要 `cd` 回主 checkout。
- **測試：RSpec + FactoryBot，不使用 fixtures。** 需維持 95%+ 行覆蓋率。測試必須打真實資料庫。
- **RuboCop Omakase**：`bin/rubocop` 必須乾淨。本專案的陣列字面值內側留空格（`[ "a", "b" ]`）。
- **i18n 三個語系必須同步**：`config/locales/zh-TW.yml`、`config/locales/zh-CN.yml`、`config/locales/en.yml`。
- **不修改業務邏輯**：`PackageSplitter` 與 `PackageMerger` 兩個服務本身不動。
- **系統測試前** `app/assets/builds/tailwind.css` 必須存在，否則 Tailwind 的 `hidden` 失效會造成大量假失敗。不存在就先跑 `bin/rails tailwindcss:build`。
- **每個任務結束時 commit**，訊息結尾加上：
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```

## File Structure

**新增**

- `app/services/package_sibling_index.rb` — 唯一職責：對一批包裹算出各自的箱號與該訂單總箱數，一次查詢完成。
- `app/javascript/turbo_stream_actions.js` — 唯一職責：註冊自訂 Turbo Stream action。
- `spec/services/package_sibling_index_spec.rb`

**修改**

- `app/controllers/packages_controller.rb` — `index` 建 sibling map；`merge` 在合併前抓住被吸收的箱子。
- `app/views/packages/_package_row.html.erb` — `<tr>` 加 dom_id、折包標記、高亮 class。
- `app/views/packages/index.html.erb` — 傳 sibling_index 給 row；modal 容器接上 `modal:dismiss`。
- `app/views/packages/split.turbo_stream.erb` — 成功時關 modal + 就地換列。
- `app/views/packages/merge.turbo_stream.erb` — 關 modal + N 列收成 1 列。
- `app/javascript/application.js`、`config/importmap.rb` — 掛載自訂 action。
- `app/assets/stylesheets/application.css` — 高亮 keyframes；修正過時註解。
- `config/locales/{zh-TW,zh-CN,en}.yml`
- `spec/requests/packages_spec.rb`、`spec/system/packages_spec.rb`

---

### Task 1: `PackageSiblingIndex` 服務

`Package#split?` 是 `order_packages.count > 1` —— 一列一次 COUNT。列表最多 50 列，若讓每列自己判斷就是 50 次查詢。這個服務用一次查詢供應整頁。

**Files:**
- Create: `app/services/package_sibling_index.rb`
- Test: `spec/services/package_sibling_index_spec.rb`

**Interfaces:**
- Consumes: 無（本計畫第一個任務）。
- Produces: `PackageSiblingIndex.new(packages)` —— `packages` 是 `Array<Package>` 或 `ActiveRecord::Relation`。`#call` → `Hash{ String => [Integer, Integer] }`，鍵是 package id、值是 `[第幾箱, 共幾箱]`。**只包含箱數 > 1 的訂單的包裹**；單箱訂單的包裹不會出現在結果中。Task 2/3/4 都靠「鍵存在與否」決定要不要畫標記。

- [ ] **Step 1: 寫失敗的測試**

Create `spec/services/package_sibling_index_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe PackageSiblingIndex do
  let(:store)    { create(:shopify_store) }
  let(:customer) { create(:customer, shopify_store: store) }

  def make_order
    create(:order, customer: customer, shopify_store: store)
  end

  def make_package(order:, number:)
    create(:package, shopify_store: store, order: order, number: number, aasm_state: "pending_process")
  end

  # Counts real SQL, skipping the schema/transaction chatter that would make the
  # assertion depend on connection warm-up rather than on this class.
  def count_queries
    count = 0
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  it "omits a package whose order has only one box" do
    order = make_order
    package = make_package(order: order, number: 1)

    expect(described_class.new([ package ]).call).to eq({})
  end

  it "numbers a three-box order 1/3, 2/3, 3/3" do
    order = make_order
    a = make_package(order: order, number: 10)
    b = make_package(order: order, number: 11)
    c = make_package(order: order, number: 12)

    result = described_class.new([ a, b, c ]).call

    expect(result[a.id]).to eq([ 1, 3 ])
    expect(result[b.id]).to eq([ 2, 3 ])
    expect(result[c.id]).to eq([ 3, 3 ])
  end

  it "orders by box number, not by creation order" do
    order = make_order
    created_first = make_package(order: order, number: 20)
    created_second = make_package(order: order, number: 5)

    result = described_class.new([ created_first, created_second ]).call

    expect(result[created_second.id]).to eq([ 1, 2 ])
    expect(result[created_first.id]).to eq([ 2, 2 ])
  end

  it "numbers each order independently" do
    order_a = make_order
    order_b = make_order
    a1 = make_package(order: order_a, number: 1)
    a2 = make_package(order: order_a, number: 2)
    b1 = make_package(order: order_b, number: 3)
    b2 = make_package(order: order_b, number: 4)
    b3 = make_package(order: order_b, number: 5)

    result = described_class.new([ a1, a2, b1, b2, b3 ]).call

    expect(result[a2.id]).to eq([ 2, 2 ])
    expect(result[b3.id]).to eq([ 3, 3 ])
  end

  it "includes a sibling that was not passed in" do
    order = make_order
    passed = make_package(order: order, number: 1)
    make_package(order: order, number: 2)

    expect(described_class.new([ passed ]).call[passed.id]).to eq([ 1, 2 ])
  end

  it "returns an empty hash for no packages without querying" do
    expect(count_queries { expect(described_class.new([]).call).to eq({}) }).to eq(0)
  end

  # Guards the whole point of this class: it must not regress to a COUNT per row.
  it "resolves a whole page of packages in a single query" do
    orders = Array.new(5) { make_order }
    packages = orders.flat_map.with_index do |order, i|
      [ make_package(order: order, number: i * 10 + 1), make_package(order: order, number: i * 10 + 2) ]
    end

    expect(count_queries { described_class.new(packages).call }).to eq(1)
  end
end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/services/package_sibling_index_spec.rb`
Expected: FAIL，`uninitialized constant PackageSiblingIndex`。

- [ ] **Step 3: 實作服務**

Create `app/services/package_sibling_index.rb`:

```ruby
# Box numbering ("box 2 of 3") for split orders, resolved for a whole page of
# packages in one query. Package#split? is a COUNT per package — fine inside a
# single modal, an N+1 across a 50-row list.
class PackageSiblingIndex
  def initialize(packages)
    @packages = packages
  end

  # => { package_id => [ position, total ] }, containing ONLY packages whose
  # order is folded into more than one box. Callers render the badge when the
  # key is present, so no caller needs its own "is this split?" test.
  def call
    order_ids = @packages.map(&:order_id).uniq
    return {} if order_ids.empty?

    rows = Package.where(order_id: order_ids).pluck(:order_id, :id, :number)
    rows.group_by(&:first).each_with_object({}) do |(_order_id, boxes), map|
      next if boxes.size < 2

      # Sorted by box NUMBER, which is what the operator sees on screen and on
      # the carrier's label — not by id or creation order, which can disagree
      # with it once a package has been split, merged, and split again.
      boxes.sort_by { |(_o, _id, number)| number }.each_with_index do |(_o, id, _n), position|
        map[id] = [ position + 1, boxes.size ]
      end
    end
  end
end
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/services/package_sibling_index_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 5: Lint**

Run: `bin/rubocop app/services/package_sibling_index.rb spec/services/package_sibling_index_spec.rb`
Expected: no offenses。

- [ ] **Step 6: Commit**

```bash
git add app/services/package_sibling_index.rb spec/services/package_sibling_index_spec.rb
git commit -m "$(cat <<'EOF'
feat(packing): add PackageSiblingIndex for split box numbering

Resolves "box N of M" for an entire page of packages in one query, instead of
the COUNT-per-row that Package#split? would cost across a 50-row list.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: 列表的折包標記與可指名的列

**Files:**
- Modify: `app/controllers/packages_controller.rb`（`index`）
- Modify: `app/views/packages/_package_row.html.erb`（第 1 行的 `<tr>`；包裹編號欄）
- Modify: `app/views/packages/index.html.erb`（第 79 行的 render 呼叫）
- Modify: `config/locales/{zh-TW,zh-CN,en}.yml`
- Test: `spec/requests/packages_spec.rb`

**Interfaces:**
- Consumes: Task 1 的 `PackageSiblingIndex.new(packages).call`。
- Produces:
  - `_package_row` partial 接受兩個新的 optional local：`sibling_index`（`[position, total]` 或 `nil`）與 `flash_highlight`（boolean，Task 3/4 使用）。
  - 每個 `<tr>` 帶 `id="package_<uuid>"`（`dom_id(package)`），Task 3/4 靠它做 `turbo_stream.replace` / `remove`。
  - i18n key `packages.split.badge`，帶 `%{position}` 與 `%{total}` 兩個插值。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/requests/packages_spec.rb` 的 `describe "GET /packages" do` 區塊內加入：

```ruby
    describe "split badge" do
      let!(:split_boxes) do
        order = create(:order, customer: customer, shopify_store: store, name: "PKS#9001")
        [
          create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 91),
          create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 92)
        ]
      end

      it "marks each box of a split order with its position and total" do
        get packages_path

        expect(response.body).to include(I18n.t("packages.split.badge", position: 1, total: 2))
        expect(response.body).to include(I18n.t("packages.split.badge", position: 2, total: 2))
      end

      it "does not mark a package whose order has a single box" do
        split_boxes.last.destroy!

        get packages_path

        expect(response.body).not_to include(I18n.t("packages.split.badge", position: 1, total: 2))
      end

      it "marks split boxes on other state pages too" do
        split_boxes.each { |box| box.update!(aasm_state: "shipped") }

        get packages_path, params: { state: "shipped" }

        expect(response.body).to include(I18n.t("packages.split.badge", position: 2, total: 2))
      end

      it "gives every row a dom id so a turbo stream can target it" do
        get packages_path

        expect(response.body).to include("id=\"#{ActionView::RecordIdentifier.dom_id(split_boxes.first)}\"")
      end
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/requests/packages_spec.rb -e "split badge"`
Expected: FAIL —— `packages.split.badge` 這個 i18n key 還不存在，`I18n.t` 會回傳 translation-missing 字串，斷言不成立。

- [ ] **Step 3: 新增 i18n**

`config/locales/zh-TW.yml` 的 `packages.split` 底下（`button:` 那一行後面）加入：

```yaml
      badge: "折 %{position}/%{total}"
```

`config/locales/zh-CN.yml` 的 `packages.split` 底下加入：

```yaml
      badge: "折 %{position}/%{total}"
```

`config/locales/en.yml` 的 `packages.split` 底下加入：

```yaml
      badge: "Split %{position}/%{total}"
```

- [ ] **Step 4: controller 建 sibling map**

`app/controllers/packages_controller.rb` 的 `index`，在 `@packages = ...` 那一段**之後**加入：

```ruby
    # One query for the whole page's box numbering — see PackageSiblingIndex.
    # Must come after @packages is materialized; it reads their order_ids.
    @sibling_index = PackageSiblingIndex.new(@packages).call
```

- [ ] **Step 5: row partial 加 dom id 與標記**

`app/views/packages/_package_row.html.erb` 第 1 行：

```erb
<tr id="<%= dom_id(package) %>" class="<%= "package-row-flash" if local_assigns[:flash_highlight] %>">
```

再找到包裹編號那個 `<td>`：

```erb
  <td class="px-4 py-3 text-sm font-medium align-top whitespace-nowrap">
    <%= link_to package.package_code, package_path(id: package.id),
        data: { turbo_frame: "package-modal" },
        class: "text-blue-600 hover:underline font-medium" %>
  </td>
```

換成：

```erb
  <td class="px-4 py-3 text-sm font-medium align-top whitespace-nowrap">
    <%= link_to package.package_code, package_path(id: package.id),
        data: { turbo_frame: "package-modal" },
        class: "text-blue-600 hover:underline font-medium" %>
    <%# Present only for an order folded into more than one box — PackageSiblingIndex
        omits single-box orders entirely, so no extra split? check is needed here. %>
    <% if local_assigns[:sibling_index] %>
      <span class="ml-1 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-orange-100 text-orange-800">
        <%= t("packages.split.badge", position: sibling_index.first, total: sibling_index.last) %>
      </span>
    <% end %>
  </td>
```

- [ ] **Step 6: index 傳入 sibling_index**

`app/views/packages/index.html.erb` 第 79 行：

```erb
                <%= render "packages/package_row", package: package, bulk: bulk %>
```

換成：

```erb
                <%= render "packages/package_row", package: package, bulk: bulk,
                      sibling_index: @sibling_index[package.id] %>
```

- [ ] **Step 7: 執行測試確認通過**

Run: `bundle exec rspec spec/requests/packages_spec.rb`
Expected: PASS，0 failures（既有範例也必須全部維持通過）。

- [ ] **Step 8: 確認列表沒有回到 N+1**

Run: `bundle exec rspec spec/system/packages_spec.rb`
Expected: PASS，0 failures。若 `app/assets/builds/tailwind.css` 不存在請先跑 `bin/rails tailwindcss:build`。

- [ ] **Step 9: Lint**

Run: `bin/rubocop app/controllers/packages_controller.rb spec/requests/packages_spec.rb`
Expected: no offenses。

- [ ] **Step 10: Commit**

```bash
git add app/controllers/packages_controller.rb app/views/packages config/locales spec/requests/packages_spec.rb
git commit -m "$(cat <<'EOF'
feat(packing): show a split badge and give each list row a dom id

Boxes of a split order now read "折 1/3" beside the package code, on every
state page. The row dom id is what the split/merge turbo streams will target.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: 折包後關閉 modal 並就地換列

**Files:**
- Create: `app/javascript/turbo_stream_actions.js`
- Modify: `config/importmap.rb`
- Modify: `app/javascript/application.js`
- Modify: `app/views/packages/index.html.erb`（modal 容器的 `data-action`）
- Modify: `app/assets/stylesheets/application.css`
- Modify: `app/views/packages/split.turbo_stream.erb`
- Test: `spec/system/packages_spec.rb`、`spec/requests/packages_spec.rb`

**Interfaces:**
- Consumes: Task 1 的 `PackageSiblingIndex`；Task 2 的 `<tr>` dom_id 與 `sibling_index` / `flash_highlight` locals。
- Produces:
  - Turbo Stream action `dismiss_modal`（無參數），任何 turbo_stream 樣板都可用 `<turbo-stream action="dismiss_modal"></turbo-stream>` 關閉包裹 modal。Task 4 會用到。
  - CSS class `package-row-flash`。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/system/packages_spec.rb` 的 `describe "折包 / 合併"` 區塊內、`it "disables submit when a box is empty (no allocation)"` 之後加入：

```ruby
    it "closes the modal and folds the row into the order's boxes in place" do
      visit packages_path(state: "pending_process")
      # A page reload would wipe this; the assertion at the end is what proves
      # the list updated over Turbo rather than by navigating.
      page.execute_script("window.__notReloaded = true")

      click_link source_pkg.package_code
      click_button I18n.t("packages.split.button")
      fill_in_first_box_input("1")
      within("[data-split-target='dialog']") { click_button I18n.t("packages.split.submit") }

      # The modal empties its frame on close, so the dialog element goes away.
      expect(page).to have_no_css("[data-split-target='dialog']")

      new_box = store.packages.where(order_id: split_order.id).where.not(id: source_pkg.id).sole
      expect(page).to have_content(new_box.package_code)
      expect(page).to have_content(I18n.t("packages.split.badge", position: 1, total: 2))
      expect(page).to have_content(I18n.t("packages.split.badge", position: 2, total: 2))

      expect(page.evaluate_script("window.__notReloaded")).to be(true)
    end
```

在 `spec/requests/packages_spec.rb` 的 `describe "POST /packages/:id/split"` 區塊內（約第 1125 行起；來源包裹的 let 名為 `src`、line item 名為 `oli`），於 `it "splits into a new sibling box and returns turbo_stream"` 之後加入：

```ruby
    it "streams a modal dismissal alongside the replaced row" do
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response.body).to include('action="dismiss_modal"')
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(src))
    end

    it "leaves the modal open with the error banner on an invalid allocation" do
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "0" ] } },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to include('action="dismiss_modal"')
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/system/packages_spec.rb -e "closes the modal and folds the row"`
Expected: FAIL —— modal 不會關，`have_no_css("[data-split-target='dialog']")` 不成立。

- [ ] **Step 3: 建立自訂 Turbo Stream action**

Create `app/javascript/turbo_stream_actions.js`:

```js
// Custom Turbo Stream actions. Turbo silently ignores an action it does not
// know, so a missing registration here shows up as "the server responded but
// nothing happened" — the system specs assert the visible outcome for exactly
// that reason.

// Closes the package detail modal from a server response. The modal's own
// Stimulus controller owns the hiding (it also clears the frame), so this only
// announces the intent and lets that controller do the work.
Turbo.StreamActions.dismiss_modal = function () {
  window.dispatchEvent(new CustomEvent("modal:dismiss"))
}
```

- [ ] **Step 4: 掛載（三處，缺一不可）**

`config/importmap.rb`，在 `pin "@hotwired/turbo-rails", to: "turbo.min.js"` 之後加入（既有的 `pin_all_from` 只涵蓋 `app/javascript/controllers`，不會收錄這個檔案）：

```ruby
pin "turbo_stream_actions"
```

`app/javascript/application.js` 換成：

```js
// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "controllers"
import "@hotwired/turbo-rails"
// Must come after turbo-rails: it reads the global Turbo that import installs.
import "turbo_stream_actions"
```

`app/views/packages/index.html.erb` 的 modal 容器：

```erb
<div data-controller="modal" data-modal-target="dialog"
     data-action="turbo:frame-load@window->modal#open"
     class="hidden fixed inset-0 z-50">
```

換成：

```erb
<div data-controller="modal" data-modal-target="dialog"
     data-action="turbo:frame-load@window->modal#open modal:dismiss@window->modal#close"
     class="hidden fixed inset-0 z-50">
```

`modal_controller` 不需要改：`close()` 本來就會清空 frame，而 `open()` 開頭就守衛 `frame.children.length === 0` 直接 return，所以清空不會反過來把 modal 彈開。

- [ ] **Step 5: 加高亮樣式並修正過時註解**

`app/assets/stylesheets/application.css`，找到既有註解中的這一句：

```
   a step this app's CI does not run before the system-spec job, so a rule
   placed there would silently not exist when spec/system exercises this
   toggle. */
```

換成：

```
   a step that has to run before the rule exists at all. (CI's system-test job
   does run it — see .github/workflows/ci.yml — but a rule served as-is by
   Propshaft cannot be missing in the first place.) */
```

然後在檔案結尾追加：

```css
/* Rows a split/merge Turbo Stream just inserted or rewrote. The list changes
   underneath the operator with no page reload, so the affected rows have to
   announce themselves — but the colour decays rather than sticking, because it
   means "this just changed", not a durable state of the package.

   Here rather than in the Tailwind source for the same reason as the rule
   above: Propshaft serves this file as-is, with no build step to forget. */
@keyframes package-row-flash {
  from { background-color: rgb(254 249 195); }
  to   { background-color: transparent; }
}

.package-row-flash {
  animation: package-row-flash 2s ease-out;
}
```

- [ ] **Step 6: 改寫折包的 turbo_stream 回應**

`app/views/packages/split.turbo_stream.erb` 整個換成：

```erb
<%# Success closes the modal and folds the source row into the order's boxes,
    in place. A full reload would scatter the new boxes through a time-sorted
    list and the operator would lose track of which ones just appeared — the
    whole point of updating in place is that they stay together, where the
    source row was.

    Failure is unchanged: re-render the modal so the dialog reopens carrying
    the error banner. %>
<% if @split_errors.present? %>
  <%= turbo_stream.replace "package-modal",
        partial: "packages/modal",
        locals: { package: @package.reload, split_errors: @split_errors } %>
<% else %>
  <turbo-stream action="dismiss_modal"></turbo-stream>
  <%# The source package survives a split — it becomes box 1, the remainder —
      so this is one row becoming N, never a delete plus inserts. %>
  <% siblings = @package.order_packages.to_a %>
  <% sibling_index = PackageSiblingIndex.new(siblings).call %>
  <%= turbo_stream.replace dom_id(@package) do %>
    <% siblings.each do |sibling| %>
      <%# bulk: true is not a guess — #split rejects any package that is not
          pending_process, and that list always renders the bulk column. A
          wrong value here would emit a row with the wrong number of cells. %>
      <%= render "packages/package_row", package: sibling, bulk: true,
            sibling_index: sibling_index[sibling.id], flash_highlight: true %>
    <% end %>
  <% end %>
<% end %>
```

- [ ] **Step 7: 執行測試確認通過**

Run: `bundle exec rspec spec/system/packages_spec.rb spec/requests/packages_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 8: Lint**

Run: `bin/rubocop config/importmap.rb`
Expected: no offenses。

- [ ] **Step 9: Commit**

```bash
git add app/javascript config/importmap.rb app/views/packages app/assets/stylesheets/application.css spec
git commit -m "$(cat <<'EOF'
feat(packing): close the modal and fold the row in place after a split

Adds a dismiss_modal Turbo Stream action and rewrites the split response to
close the modal and replace the source row with the order's boxes, flashed so
the operator can see which rows just appeared. A reload would have scattered
them through a time-sorted list.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: 合併後關閉 modal 並收回單列

**Files:**
- Modify: `app/controllers/packages_controller.rb`（`merge`，約第 206–217 行）
- Modify: `app/views/packages/merge.turbo_stream.erb`
- Test: `spec/system/packages_spec.rb`、`spec/requests/packages_spec.rb`

**Interfaces:**
- Consumes: Task 3 的 `dismiss_modal` action 與 `package-row-flash`；Task 2 的 row dom_id；Task 1 的 `PackageSiblingIndex`。
- Produces: 無新介面。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/system/packages_spec.rb` 的 `describe "折包 / 合併"` 區塊內、既有的 `it "merges split boxes back into one and shows the survivor"` 之後加入：

```ruby
    it "closes the modal and collapses the boxes back to one row in place" do
      other = create(:package, shopify_store: store, order: split_order, number: 701, aasm_state: "pending_process")
      create(:package_item, package: other, order_line_item: oli, sku: "SPLITSKU", quantity: 1)
      source_pkg.package_items.first.update!(quantity: 2)

      visit packages_path(state: "pending_process")
      page.execute_script("window.__notReloaded = true")
      expect(page).to have_content(other.package_code)

      click_link source_pkg.package_code
      accept_confirm { click_button I18n.t("packages.merge.button") }

      expect(page).to have_no_css("[data-split-target='dialog']")
      expect(page).to have_content(source_pkg.package_code)
      expect(page).to have_no_content(other.package_code)
      expect(page.evaluate_script("window.__notReloaded")).to be(true)
    end
```

在 `spec/requests/packages_spec.rb` 的合併 request spec 區塊內（約第 1186 行起；存活箱的 let 名為 `survivor`、被吸收的箱子名為 `other`），於 `it "merges the order's boxes back into one and returns turbo_stream"` 之後加入。注意合併是對 `other` 發動的，但存活的是編號較小的 `survivor`：

```ruby
    it "streams a modal dismissal and removes the absorbed row" do
      post merge_package_path(id: other.id),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response.body).to include('action="dismiss_modal"')
      expect(response.body).to include('action="remove"')
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(other))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(survivor))
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/system/packages_spec.rb -e "collapses the boxes back to one row"`
Expected: FAIL —— modal 不會關，且被合併掉的包裹編號仍留在列表上。

- [ ] **Step 3: controller 在合併前抓住被吸收的箱子**

`app/controllers/packages_controller.rb` 的 `merge`，把：

```ruby
    @survivor = PackageMerger.new(@package).call
```

換成：

```ruby
    # PackageMerger destroys the absorbed boxes, so the rows to remove from the
    # list have to be captured BEFORE the call — afterwards there is nothing
    # left to ask. These are in-memory (now destroyed) records, which is all
    # dom_id needs. Note the merger only folds pending_process siblings, so a
    # box of this order sitting in another state is deliberately not in here.
    merger = PackageMerger.new(@package)
    siblings = merger.pending_siblings
    @survivor = merger.call
    @absorbed = siblings.reject { |box| box.id == @survivor.id }
```

- [ ] **Step 4: 改寫合併的 turbo_stream 回應**

`app/views/packages/merge.turbo_stream.erb` 整個換成：

```erb
<%# Mirror of split.turbo_stream.erb: close the modal, then collapse the boxes
    back to a single row where they were. The absorbed boxes no longer exist in
    the database, so their rows have to be removed explicitly — leaving them on
    screen would offer the operator packages that 404 on click. %>
<turbo-stream action="dismiss_modal"></turbo-stream>
<% survivor = @survivor.reload %>
<% sibling_index = PackageSiblingIndex.new([ survivor ]).call %>
<%= turbo_stream.replace dom_id(survivor) do %>
  <%= render "packages/package_row", package: survivor, bulk: true,
        sibling_index: sibling_index[survivor.id], flash_highlight: true %>
<% end %>
<% @absorbed.each do |box| %>
  <%= turbo_stream.remove dom_id(box) %>
<% end %>
```

- [ ] **Step 5: 執行測試確認通過**

Run: `bundle exec rspec spec/system/packages_spec.rb spec/requests/packages_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 6: 全套件驗證**

Run: `bundle exec rspec`
Expected: PASS，0 failures，行覆蓋率 ≥ 95%。若覆蓋率未達標，找出未覆蓋的新程式碼並補測試——不要調低門檻。

- [ ] **Step 7: 完整 CI 檢查**

Run: `bin/rubocop && bin/brakeman --no-pager && bin/bundler-audit && bin/importmap audit`
Expected: 全部乾淨。

注意：在這個 worktree 裡跑 `bin/rubocop` 會誤報約 286 個 `db/schema.rb` 的 offenses——`.rubocop.yml` 的排除規則在 worktree 的點路徑下比對不到。那些不是真的，只檢查你改過的檔案。

- [ ] **Step 8: Commit**

```bash
git add app/controllers/packages_controller.rb app/views/packages/merge.turbo_stream.erb spec
git commit -m "$(cat <<'EOF'
feat(packing): close the modal and collapse rows in place after a merge

Mirrors the split response. The absorbed boxes are captured before the merge
runs, since PackageMerger destroys them and their rows would otherwise stay on
screen offering packages that no longer exist.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## 完成後

全部任務完成、`bundle exec rspec` 全綠、CI 檢查乾淨後，使用 `superpowers:finishing-a-development-branch` skill 決定如何整合（本專案流程為：feature branch → PR 到 `staging`）。
