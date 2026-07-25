# 打包列表篩選、排序與批量審核 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓打包模組的列表可跨店鋪檢視、依國家篩選、依建包／下單／付款時間升降序排序，並在「待審核」列表支援批量審核。

**Architecture:** 篩選與排序邏輯集中在新的查詢物件 `PackageListQuery`（`app/services/`），`PackagesController#index` 只負責解析狀態、組出已授權的 scope、交給查詢物件、分頁。國家取值用一段 SQL `COALESCE` 運算式同時驅動「可選清單」與「篩選條件」，確保列表顯示什麼就能篩到什麼。付款時間需要新的 `orders.paid_at` 欄位（來自 Shopify `processed_at`）才能有效率排序。批量審核沿用既有 `apply_tracking_bulk` / `ship_bulk` 的逐筆隔離模式。

**Tech Stack:** Rails 8.1、PostgreSQL（UUID 主鍵、jsonb）、Hotwire（Turbo + Stimulus）、Tailwind CSS、RSpec + FactoryBot、AASM。

**Spec:** `docs/superpowers/specs/2026-07-25-packages-list-filters-design.md`

## Global Constraints

- **絕不直接 commit 到 `main` 或 `staging`。** 本計畫在 `feature/packing-review-filters` 分支上執行。
- **所有 table 主鍵使用 UUID。**
- **測試：RSpec + FactoryBot，不使用 fixtures。** 需 95%+ 行覆蓋率，PR 才會被核准。測試必須打真實資料庫；既有對外部 HTTP 服務（`ShopifyService`）使用 `instance_double` 的作法可沿用。
- **每個任務都要有 model spec / request spec / system spec 的適當組合。**
- **RuboCop Omakase**：`bin/rubocop` 必須乾淨。陣列字面值內側留空格（`[ "a", "b" ]`）是本專案既有風格。
- **i18n 三個語系必須同步**：`config/locales/zh-TW.yml`、`config/locales/zh-CN.yml`、`config/locales/en.yml`。任何新增文案三個檔都要補。
- **參數命名沿用訂單頁既有慣例**：排序參數為 `sort_column` 與 `sort_direction`（見 `app/controllers/orders_controller.rb:2`），不得另創 `sort` / `dir`。
- **每個任務結束時 commit。** Commit message 結尾加上：
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```
- **執行環境**：worktree 位於 `/opt/dev/ecom_admin_app/.claude/worktrees/packing-review-filters`，所有指令都在此目錄執行，不要 `cd` 回主 checkout。系統測試前若 `app/assets/builds/tailwind.css` 不存在，先跑 `bin/rails tailwindcss:build`，否則 Tailwind 的 `hidden` 類別失效會讓系統測試大量假失敗。

## File Structure

**新增**

- `app/services/package_list_query.rb` — 唯一職責：把「已授權的 package scope」加上國家篩選與排序，並回報該範圍內可選的國家清單。不碰授權、不碰分頁。
- `app/helpers/packages_helper.rb` — 唯一職責：列表連結組裝（保留當前篩選、覆寫指定參數）。
- `app/views/packages/_filter_bar.html.erb` — 唯一職責：渲染國家膠囊列與排序列。
- `db/migrate/<timestamp>_add_paid_at_to_orders.rb`
- `spec/services/package_list_query_spec.rb`

**修改**

- `app/controllers/admin_controller.rb:29` — `STORE_ALL_ALLOWED_CONTROLLERS` 加入 `"packages"`。
- `app/controllers/packages_controller.rb` — `index` 接上查詢物件；新增 `submit_review_bulk` action 與 `list_filter_params` 私有方法；`apply_tracking_bulk` / `ship_bulk` 的 redirect 帶回篩選。
- `app/models/order.rb` — `paid_at` 語意註解。
- `app/services/sync_all_orders_service.rb:90` 附近 — 寫入 `paid_at`。
- `app/services/shopify_lookup_service.rb:62` 附近 — 寫入 `paid_at`。
- `app/views/packages/index.html.erb` — 掛上篩選列；表頭時間欄與店鋪欄；批量審核納入 `bulk`；篩選 hidden fields。
- `app/views/packages/_package_row.html.erb` — 時間欄改雙行且用店鋪時區；跨店鋪時多一欄店鋪名。
- `app/views/packages/_order_info.html.erb` — 新增建包時間顯示。
- `app/views/packages/_pagination.html.erb` — 改用新 helper 組連結。
- `config/routes.rb` — `submit_review_bulk` collection route。
- `config/locales/{zh-TW,zh-CN,en}.yml`
- `spec/requests/packages_spec.rb`、`spec/system/packages_spec.rb`、`spec/services/sync_all_orders_service_spec.rb`、`spec/services/shopify_lookup_service_spec.rb`、`spec/factories/orders.rb`

---

### Task 1: `orders.paid_at` 欄位與同步寫入

Shopify 訂單沒有獨立的付款時間欄位；最接近的是 REST payload 的 `processed_at`。它目前只存在 `orders.shopify_data` JSON 裡，無法有效率排序。這個任務把它提取成真欄位。

**Files:**
- Create: `db/migrate/<timestamp>_add_paid_at_to_orders.rb`
- Modify: `app/models/order.rb`
- Modify: `app/services/sync_all_orders_service.rb`（`attrs` 雜湊，約在 `ordered_at:` 那一行下方）
- Modify: `app/services/shopify_lookup_service.rb`（`attrs` 雜湊，約在 `ordered_at:` 那一行下方）
- Modify: `spec/factories/orders.rb`
- Test: `spec/services/sync_all_orders_service_spec.rb`、`spec/services/shopify_lookup_service_spec.rb`

**Interfaces:**
- Consumes: 無（本計畫第一個任務）
- Produces: `Order#paid_at`（`ActiveSupport::TimeWithZone` 或 `nil`）。Task 2 的 `PackageListQuery::SORT_COLUMNS` 以 `orders.paid_at` 引用它；Task 5 的列表以 `package.order.paid_at` 顯示它。`:order` factory 新增 `paid_at` 屬性，預設與 `ordered_at` 同值。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/services/sync_all_orders_service_spec.rb` 中，`shopify_order` 這個 `let` 的雜湊加入 `processed_at`（放在 `"created_at" => "2026-03-20",` 那一行後面）：

```ruby
        "created_at" => "2026-03-20",
        "processed_at" => "2026-03-21T08:30:00Z",
```

然後在 `it "sets correct order attributes" do` 這個範例之後，新增兩個範例：

```ruby
    it "stores the Shopify processed_at as the order's paid_at" do
      service.call

      order = Order.find_by(shopify_order_id: 200)
      expect(order.paid_at).to eq(Time.utc(2026, 3, 21, 8, 30, 0))
    end

    context "when the payload has no processed_at" do
      let(:shopify_order) do
        {
          "id" => 201, "email" => "buyer@example.com", "name" => "#1002",
          "total_price" => "10.00", "currency" => "USD",
          "financial_status" => "pending", "fulfillment_status" => nil,
          "created_at" => "2026-03-20",
          "customer" => shopify_customer,
          "fulfillments" => []
        }
      end

      it "leaves paid_at nil rather than guessing" do
        service.call

        expect(Order.find_by(shopify_order_id: 201).paid_at).to be_nil
      end
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/services/sync_all_orders_service_spec.rb -e "processed_at"`
Expected: FAIL，錯誤訊息類似 `undefined method 'paid_at' for #<Order...>`（欄位還不存在）。

- [ ] **Step 3: 產生 migration**

Run: `bin/rails generate migration AddPaidAtToOrders paid_at:datetime`

把產生的檔案內容改成（`<VERSION>` 保留 Rails 產生的版本號）：

```ruby
class AddPaidAtToOrders < ActiveRecord::Migration[8.1]
  def up
    add_column :orders, :paid_at, :datetime
    add_index :orders, [ :shopify_store_id, :paid_at ], name: "idx_orders_store_paid_at"

    # Backfill in Ruby, one row at a time, rather than a single
    # `UPDATE ... (shopify_data->>'processed_at')::timestamptz`. shopify_data is
    # raw third-party JSON this app never validates on write, and a Postgres cast
    # raises on the first unparseable value — taking the whole migration with it.
    # A regex guard does not save it either: '2026-99-99' is well-formed and
    # still fails to cast. One bad row must cost one row, not the deploy.
    Order.reset_column_information
    Order.where.not(shopify_data: nil).find_each(batch_size: 500) do |order|
      raw = order.shopify_data.is_a?(Hash) ? order.shopify_data["processed_at"] : nil
      next if raw.blank?

      begin
        order.update_column(:paid_at, Time.zone.parse(raw.to_s))
      rescue ArgumentError, TypeError => e
        say "skipped Order #{order.id}: unparseable processed_at #{raw.inspect} (#{e.class})"
      end
    end
  end

  def down
    remove_index :orders, name: "idx_orders_store_paid_at"
    remove_column :orders, :paid_at
  end
end
```

`Time.zone.parse` 對 `"2026-99-99"` 會拋 `ArgumentError`（而非回傳 nil），所以 `rescue` 是必要的、不是裝飾。

- [ ] **Step 4: 執行 migration**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: migration 成功，`db/schema.rb` 出現 `t.datetime "paid_at"` 與 `idx_orders_store_paid_at`。

- [ ] **Step 5: 寫入 paid_at（兩個同步路徑）**

在 `app/services/sync_all_orders_service.rb` 的 `attrs` 雜湊中，`ordered_at:` 下方加入：

```ruby
      ordered_at: shopify_order["created_at"],
      paid_at: shopify_order["processed_at"],
```

在 `app/services/shopify_lookup_service.rb` 的 `attrs` 雜湊中做完全相同的加入：

```ruby
        ordered_at: shopify_order["created_at"],
        paid_at: shopify_order["processed_at"],
```

兩處都必須改。只改一處會讓不同同步路徑寫出不一致的資料。

在 `app/models/order.rb` 的 class 開頭（`belongs_to` 之上）加註解：

```ruby
  # paid_at is a SORTING PROXY for payment time, not a settlement timestamp.
  # Shopify exposes no "paid at" field on the order payload, and this app does
  # not mirror Shopify transactions/captures, so the closest available value is
  # the order's `processed_at` (when Shopify processed the payment). Do not use
  # it for reconciliation — that needs a real transactions sync.
  #
  # Written unconditionally rather than gated on financial_status: a
  # status-conditional write would make the column flip back to nil when an
  # order is later refunded. The packing module only builds packages for
  # paid/partially_paid orders (PackageAutoBuilder::PAID_STATUSES), so every
  # order surfaced in the packing list has it set.
```

- [ ] **Step 6: 執行測試確認通過**

Run: `bundle exec rspec spec/services/sync_all_orders_service_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 7: factory 補上 paid_at**

`spec/factories/orders.rb` 的 `ordered_at { 1.day.ago }` 下方加入：

```ruby
    paid_at { 1.day.ago }
```

- [ ] **Step 8: 補 shopify_lookup_service 的測試**

`spec/services/shopify_lookup_service_spec.rb` 的第一個範例 `it "creates customer, orders, and fulfillments from Shopify data"` 之後，插入這個新範例（`ticket`、`shopify_service`、`service` 都是該檔案頂層既有的 `let`）：

```ruby
    it "stores the Shopify processed_at as the order's paid_at" do
      allow(shopify_service).to receive(:find_customers_by_email).with("buyer@example.com").and_return([
        { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane", "last_name" => "Buyer" }
      ])

      allow(shopify_service).to receive(:fetch_orders).with(100).and_return([
        { "id" => 200, "email" => "buyer@example.com", "name" => "#1001", "total_price" => "49.99",
          "currency" => "USD", "financial_status" => "paid", "fulfillment_status" => "fulfilled",
          "created_at" => "2026-03-20", "processed_at" => "2026-03-21T08:30:00Z" }
      ])

      allow(shopify_service).to receive(:fetch_fulfillments).with(200).and_return([])

      service.lookup(ticket)

      expect(Order.find_by(shopify_order_id: 200).paid_at).to eq(Time.utc(2026, 3, 21, 8, 30, 0))
    end
```

- [ ] **Step 9: 執行完整相關測試**

Run: `bundle exec rspec spec/services/sync_all_orders_service_spec.rb spec/services/shopify_lookup_service_spec.rb spec/models/order_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 10: Lint**

Run: `bin/rubocop app/services/sync_all_orders_service.rb app/services/shopify_lookup_service.rb app/models/order.rb db/migrate spec/factories/orders.rb`
Expected: no offenses。

- [ ] **Step 11: Commit**

```bash
git add db/migrate db/schema.rb app/models/order.rb app/services/sync_all_orders_service.rb app/services/shopify_lookup_service.rb spec/factories/orders.rb spec/services/sync_all_orders_service_spec.rb spec/services/shopify_lookup_service_spec.rb
git commit -m "$(cat <<'EOF'
feat(orders): add paid_at column sourced from Shopify processed_at

Backfills from the stored shopify_data payload and writes it on both sync
paths so the packing list can sort by payment time without scanning jsonb.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `PackageListQuery` 查詢物件

**Files:**
- Create: `app/services/package_list_query.rb`
- Test: `spec/services/package_list_query_spec.rb`

**Interfaces:**
- Consumes: Task 1 的 `orders.paid_at` 欄位。
- Produces:
  - `PackageListQuery::SORT_COLUMNS` — `Hash`，鍵為 `"created_at"` / `"ordered_at"` / `"paid_at"`（view 依此順序渲染排序項），值為 SQL 欄位字串。
  - `PackageListQuery.new(scope, country:, sort_column:, sort_direction:)` — 全部為關鍵字參數且皆可為 `nil`。
  - `#countries` → `Array<String>`（大寫 ISO alpha-2，去重，未排序）
  - `#country` → `String` 或 `nil`（正規化後）
  - `#sort_column` → `String`（正規化後，必為 `SORT_COLUMNS` 的鍵）
  - `#sort_direction` → `String`（`"asc"` 或 `"desc"`）
  - `#relation` → `ActiveRecord::Relation`（已 `joins(:order)`、已套篩選與排序，未分頁）

- [ ] **Step 1: 寫失敗的測試**

Create `spec/services/package_list_query_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe PackageListQuery do
  let(:store)    { create(:shopify_store) }
  let(:customer) { create(:customer, shopify_store: store) }
  let(:scope)    { Package.where(shopify_store_id: store.id, aasm_state: "pending_review") }

  # snapshot_country: 寫進 package 的地址快照（列表優先取這個）
  # shopify_country:  寫進訂單的 Shopify 原始地址（快照缺值時的退路）
  def make_package(number:, snapshot_country: nil, shopify_country: nil,
                   ordered_at: 1.day.ago, paid_at: 1.day.ago, created_at: 1.day.ago)
    shopify_data = shopify_country ? { "shipping_address" => { "country_code" => shopify_country } } : {}
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: ordered_at, paid_at: paid_at, shopify_data: shopify_data)
    snapshot = snapshot_country ? { "country_code" => snapshot_country } : {}
    create(:package, shopify_store: store, order: order, number: number,
           created_at: created_at, shipping_address_snapshot: snapshot)
  end

  describe "#countries" do
    it "returns the distinct country codes present in the scope" do
      make_package(number: 1, snapshot_country: "US")
      make_package(number: 2, snapshot_country: "US")
      make_package(number: 3, snapshot_country: "CA")

      expect(described_class.new(scope).countries).to match_array(%w[US CA])
    end

    it "falls back to the order's Shopify address when the snapshot has no country" do
      make_package(number: 1, shopify_country: "DE")

      expect(described_class.new(scope).countries).to eq([ "DE" ])
    end

    it "ignores packages with no country anywhere" do
      make_package(number: 1, snapshot_country: "US")
      make_package(number: 2)

      expect(described_class.new(scope).countries).to eq([ "US" ])
    end

    it "treats a whitespace-only snapshot country as absent and falls back" do
      make_package(number: 1, snapshot_country: "   ", shopify_country: "GB")

      expect(described_class.new(scope).countries).to eq([ "GB" ])
    end

    it "normalizes case so a hand-edited lowercase code is not a separate bucket" do
      make_package(number: 1, snapshot_country: "US")
      make_package(number: 2, snapshot_country: "us")

      expect(described_class.new(scope).countries).to eq([ "US" ])
    end
  end

  describe "#country" do
    it "accepts a country present in the scope" do
      make_package(number: 1, snapshot_country: "US")

      expect(described_class.new(scope, country: "US").country).to eq("US")
    end

    it "upcases the incoming value" do
      make_package(number: 1, snapshot_country: "US")

      expect(described_class.new(scope, country: "us").country).to eq("US")
    end

    it "ignores a country that is not in the scope" do
      make_package(number: 1, snapshot_country: "US")

      expect(described_class.new(scope, country: "CA").country).to be_nil
    end

    it "ignores a blank country" do
      make_package(number: 1, snapshot_country: "US")

      expect(described_class.new(scope, country: "").country).to be_nil
    end
  end

  describe "#relation country filtering" do
    it "keeps only packages matching the country" do
      us = make_package(number: 1, snapshot_country: "US")
      make_package(number: 2, snapshot_country: "CA")

      expect(described_class.new(scope, country: "US").relation).to eq([ us ])
    end

    it "matches on the order's Shopify address when the snapshot has no country" do
      de = make_package(number: 1, shopify_country: "DE")
      make_package(number: 2, snapshot_country: "US")

      expect(described_class.new(scope, country: "DE").relation).to eq([ de ])
    end

    it "matches a hand-edited lowercase country code" do
      lower = make_package(number: 1, snapshot_country: "us")
      make_package(number: 2, snapshot_country: "CA")

      expect(described_class.new(scope, country: "US").relation).to eq([ lower ])
    end

    it "returns everything when the country is not in the scope" do
      make_package(number: 1, snapshot_country: "US")
      make_package(number: 2, snapshot_country: "CA")

      expect(described_class.new(scope, country: "JP").relation.count).to eq(2)
    end
  end

  describe "#relation sorting" do
    it "defaults to newest package first" do
      old = make_package(number: 1, created_at: 3.days.ago)
      new = make_package(number: 2, created_at: 1.hour.ago)

      expect(described_class.new(scope).relation).to eq([ new, old ])
    end

    it "sorts by the order's ordered_at ascending" do
      late  = make_package(number: 1, ordered_at: 1.hour.ago)
      early = make_package(number: 2, ordered_at: 5.days.ago)

      result = described_class.new(scope, sort_column: "ordered_at", sort_direction: "asc").relation
      expect(result).to eq([ early, late ])
    end

    it "sorts by the order's paid_at descending" do
      early = make_package(number: 1, paid_at: 5.days.ago)
      late  = make_package(number: 2, paid_at: 1.hour.ago)

      result = described_class.new(scope, sort_column: "paid_at", sort_direction: "desc").relation
      expect(result).to eq([ late, early ])
    end

    it "puts records with no paid_at last even when sorting ascending" do
      paid   = make_package(number: 1, paid_at: 5.days.ago)
      unpaid = make_package(number: 2, paid_at: nil)

      result = described_class.new(scope, sort_column: "paid_at", sort_direction: "asc").relation
      expect(result).to eq([ paid, unpaid ])
    end

    it "breaks ties on id so pagination stays stable" do
      at = 2.days.ago
      make_package(number: 1, created_at: at)
      make_package(number: 2, created_at: at)

      first_run  = described_class.new(scope).relation.pluck(:id)
      second_run = described_class.new(scope).relation.pluck(:id)
      expect(first_run).to eq(second_run)
      expect(first_run.uniq.size).to eq(2)
    end

    it "falls back to the default column for an unknown sort_column" do
      query = described_class.new(scope, sort_column: "drop table")
      expect(query.sort_column).to eq("created_at")
    end

    it "falls back to desc for an unknown sort_direction" do
      query = described_class.new(scope, sort_direction: "sideways")
      expect(query.sort_direction).to eq("desc")
    end

    it "accepts asc as a sort_direction" do
      query = described_class.new(scope, sort_direction: "asc")
      expect(query.sort_direction).to eq("asc")
    end
  end
end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/services/package_list_query_spec.rb`
Expected: FAIL，`uninitialized constant PackageListQuery`。

- [ ] **Step 3: 實作查詢物件**

Create `app/services/package_list_query.rb`:

```ruby
# Filtering + ordering for the packing list. The caller passes in an ALREADY
# authorized scope (company/store/state applied) — this object never widens it
# and knows nothing about permissions. Pagination stays in the controller.
class PackageListQuery
  # The list renders the package's own address snapshot and falls back to the
  # order's raw Shopify address when the snapshot has no country (see
  # _package_row.html.erb). Both the selectable-country list and the filter
  # itself must use this SAME expression — otherwise a row displaying 美國
  # would not come back when the user clicks 美國.
  #
  # NULLIF(TRIM(...), '') mirrors Order::DESTINATION_COUNTRY_SQL, this app's
  # existing way of reading a country code out of Shopify JSON, so a
  # whitespace-only value counts as absent in both places.
  #
  # UPPER is not paranoia: #update_address lets a human hand-edit the snapshot
  # (ADDRESS_KEYS includes country_code) with no normalization, so a lowercase
  # "us" really can land in the column and would otherwise split one country
  # into two pills.
  COUNTRY_SQL = <<~SQL.squish
    COALESCE(
      UPPER(NULLIF(TRIM(packages.shipping_address_snapshot->>'country_code'), '')),
      UPPER(NULLIF(TRIM(orders.shopify_data #>> '{shipping_address,country_code}'), ''))
    )
  SQL

  # Insertion order drives the order of the sort controls in the filter bar.
  SORT_COLUMNS = {
    "created_at" => "packages.created_at",
    "ordered_at" => "orders.ordered_at",
    "paid_at"    => "orders.paid_at"
  }.freeze
  DEFAULT_SORT_COLUMN = "created_at"

  attr_reader :sort_column, :sort_direction

  def initialize(scope, country: nil, sort_column: nil, sort_direction: nil)
    # packages.order is a required belongs_to, so this inner join never drops a
    # row — joining unconditionally keeps the SQL identical whether or not the
    # country filter and order-based sorts are in play.
    @scope = scope.joins(:order)
    @requested_country = country.to_s.upcase.presence
    @sort_column = SORT_COLUMNS.key?(sort_column) ? sort_column : DEFAULT_SORT_COLUMN
    @sort_direction = sort_direction == "asc" ? "asc" : "desc"
  end

  # Country codes that actually occur in this scope. Sorting is left to the
  # view, which orders by the localized country name — not something SQL can do.
  def countries
    @countries ||= @scope.reorder(nil).distinct.pluck(Arel.sql(COUNTRY_SQL)).compact_blank
  end

  # Only a country actually present in this scope is honoured; anything else
  # (unknown code, blank, junk) falls through to "all" rather than 404ing or
  # showing an empty list the user can't explain.
  def country
    return @country if defined?(@country)

    @country = countries.include?(@requested_country) ? @requested_country : nil
  end

  def relation
    rel = @scope
    rel = rel.where("#{COUNTRY_SQL} = ?", country) if country
    rel.reorder(Arel.sql(order_sql))
  end

  private

  # NULLS LAST in BOTH directions: ordered_at/paid_at are nullable, and an
  # ascending sort would otherwise open on a page of blanks. packages.id is the
  # tie-breaker — without one, rows sharing a timestamp can repeat or vanish
  # across page boundaries.
  #
  # Both interpolated values come from the constant tables above (never from
  # user input), so this string can never carry an injection.
  def order_sql
    "#{SORT_COLUMNS.fetch(sort_column)} #{sort_direction} NULLS LAST, packages.id #{sort_direction}"
  end
end
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/services/package_list_query_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 5: Lint**

Run: `bin/rubocop app/services/package_list_query.rb spec/services/package_list_query_spec.rb`
Expected: no offenses。

- [ ] **Step 6: Commit**

```bash
git add app/services/package_list_query.rb spec/services/package_list_query_spec.rb
git commit -m "$(cat <<'EOF'
feat(packing): add PackageListQuery for country filtering and sorting

One SQL expression drives both the selectable country list and the filter so
the list can always be filtered by what it displays. Sorts get NULLS LAST and
an id tie-breaker for stable pagination.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Controller 接上查詢物件

**Files:**
- Modify: `app/controllers/packages_controller.rb`（`index`，第 16–27 行）
- Test: `spec/requests/packages_spec.rb`（在 `describe "GET /packages" do` 區塊內新增）

**Interfaces:**
- Consumes: Task 2 的 `PackageListQuery`。
- Produces: `index` 設定的 instance variables，供 Task 5 的 view 使用 —— `@countries`（`Array<String>`）、`@country`（`String` 或 `nil`）、`@sort_column`（`String`）、`@sort_direction`（`String`）。既有的 `@state` / `@page` / `@total_count` / `@total_pages` / `@packages` 語意不變。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/requests/packages_spec.rb` 的 `describe "GET /packages" do` 區塊內、`it "falls back to pending_review for an unknown state param"` 之後，加入：

```ruby
    describe "country filter and sorting" do
      let!(:us_package) do
        order = create(:order, customer: customer, shopify_store: store, name: "PKS#5001",
                       ordered_at: 5.days.ago, paid_at: 5.days.ago)
        create(:package, shopify_store: store, order: order, aasm_state: "pending_review",
               number: 51, created_at: 5.days.ago,
               shipping_address_snapshot: { "country_code" => "US" })
      end

      let!(:ca_package) do
        order = create(:order, customer: customer, shopify_store: store, name: "PKS#5002",
                       ordered_at: 1.hour.ago, paid_at: 1.hour.ago)
        create(:package, shopify_store: store, order: order, aasm_state: "pending_review",
               number: 52, created_at: 1.hour.ago,
               shipping_address_snapshot: { "country_code" => "CA" })
      end

      it "filters the list to the requested country" do
        get packages_path, params: { country: "US" }

        expect(response.body).to include("PKS#5001")
        expect(response.body).not_to include("PKS#5002")
      end

      it "ignores a country that is not present in the list" do
        get packages_path, params: { country: "JP" }

        expect(response.body).to include("PKS#5001")
        expect(response.body).to include("PKS#5002")
      end

      it "sorts by the order's ordered_at ascending" do
        get packages_path, params: { sort_column: "ordered_at", sort_direction: "asc" }

        expect(response.body.index("PKS#5001")).to be < response.body.index("PKS#5002")
      end

      it "sorts by the order's paid_at descending" do
        get packages_path, params: { sort_column: "paid_at", sort_direction: "desc" }

        expect(response.body.index("PKS#5002")).to be < response.body.index("PKS#5001")
      end

      it "falls back to the default sort for junk sort params" do
        get packages_path, params: { sort_column: "; drop table", sort_direction: "sideways" }

        expect(response).to have_http_status(:ok)
        expect(response.body.index("PKS#5002")).to be < response.body.index("PKS#5001")
      end
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/requests/packages_spec.rb -e "country filter and sorting"`
Expected: FAIL —— 篩選與排序尚未實作，`filters the list to the requested country` 會因為 `PKS#5002` 仍出現而失敗。

- [ ] **Step 3: 改寫 index**

把 `app/controllers/packages_controller.rb` 的 `index` 整個換成：

```ruby
  def index
    @state = STATES.include?(params[:state]) ? params[:state] : "pending_review"
    scope = scoped_packages.where(aasm_state: @state)
    scope = scope.where(application_status: params[:application_status]) if @state == "applying_tracking" && APPLICATION_STATUSES.include?(params[:application_status])

    # Filtering/ordering lives in the query object; the scope handed to it is
    # already company/store/state-authorized and the query object never widens
    # it. Pagination stays here.
    query = PackageListQuery.new(scope, country: params[:country],
                                        sort_column: params[:sort_column],
                                        sort_direction: params[:sort_direction])
    # Ordered by the LOCALIZED country name, which SQL can't do — parcel_country_name
    # resolves through i18n. Reached via the `helpers` proxy rather than including
    # ParcelsHelper, which would graft all its public methods onto the controller.
    @countries = query.countries.sort_by { |code| helpers.parcel_country_name(code).to_s }
    @country = query.country
    @sort_column = query.sort_column
    @sort_direction = query.sort_direction

    filtered = query.relation
    @page = [ params[:page].to_i, 1 ].max
    @total_count = filtered.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0
    @packages = filtered.includes(:order, :package_items, :shopify_store, :logistics_channel)
                        .offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end
```

`parcel_country_name` 定義在 `ParcelsHelper`，透過 Rails 的 `helpers` proxy 取用，不需要 `include`，controller 也不會多出一堆公開方法。

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/requests/packages_spec.rb`
Expected: PASS，0 failures（既有範例也必須全部維持通過）。

- [ ] **Step 5: 確認排序未破壞既有列表行為**

Run: `bundle exec rspec spec/system/packages_spec.rb`
Expected: PASS，23 examples 0 failures。若 `app/assets/builds/tailwind.css` 不存在請先跑 `bin/rails tailwindcss:build`。

- [ ] **Step 6: Lint 與安全掃描**

Run: `bin/rubocop app/controllers/packages_controller.rb spec/requests/packages_spec.rb && bin/brakeman --no-pager`
Expected: rubocop no offenses；brakeman 0 warnings（特別確認沒有新的 SQL Injection 警告）。

- [ ] **Step 7: Commit**

```bash
git add app/controllers/packages_controller.rb spec/requests/packages_spec.rb
git commit -m "$(cat <<'EOF'
feat(packing): wire the packing list to PackageListQuery

index now honours country/sort_column/sort_direction params, falling back to
the previous created_at desc default for missing or junk values.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: 店鋪「全部」選項與列表店鋪欄

**Files:**
- Modify: `app/controllers/admin_controller.rb:29`
- Modify: `app/views/packages/index.html.erb`（表頭與空列的 colspan）
- Modify: `app/views/packages/_package_row.html.erb`
- Modify: `config/locales/{zh-TW,zh-CN,en}.yml`（`packages.columns.store`）
- Test: `spec/requests/packages_spec.rb`

**Interfaces:**
- Consumes: 無新依賴。
- Produces: 打包頁在未指定 `store_id` 時 `current_shopify_store` 為 `nil`，列表涵蓋所有可見店鋪。Task 5 修改同兩個 view 檔時必須保留本任務加入的店鋪欄與 colspan 計算。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/requests/packages_spec.rb` 的 `describe "GET /packages" do` 區塊內加入：

```ruby
    describe "cross-store listing" do
      let(:other_store) { create(:shopify_store, user: user, company: company) }
      let(:other_customer) { create(:customer, shopify_store: other_store) }

      let!(:other_store_package) do
        order = create(:order, customer: other_customer, shopify_store: other_store, name: "PKS#6001")
        create(:package, shopify_store: other_store, order: order, aasm_state: "pending_review", number: 61)
      end

      it "lists packages from every visible store by default" do
        get packages_path

        expect(response.body).to include("PKS#1001")
        expect(response.body).to include("PKS#6001")
      end

      it "shows the store name column when no single store is selected" do
        get packages_path

        expect(response.body).to include(I18n.t("packages.columns.store"))
        expect(response.body).to include(other_store.name)
      end

      it "narrows to one store when store_id is given" do
        get packages_path, params: { store_id: store.id }

        expect(response.body).to include("PKS#1001")
        expect(response.body).not_to include("PKS#6001")
      end
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/requests/packages_spec.rb -e "cross-store listing"`
Expected: FAIL —— `lists packages from every visible store by default` 失敗，因為預設仍收斂到第一間店。

- [ ] **Step 3: 開放「全部」**

`app/controllers/admin_controller.rb` 第 29 行改為：

```ruby
  STORE_ALL_ALLOWED_CONTROLLERS = %w[dashboard shipments packages].freeze
```

- [ ] **Step 4: i18n 新增店鋪欄標題**

`config/locales/zh-TW.yml` 的 `packages.columns` 底下加入：

```yaml
      store: "店鋪"
```

`config/locales/zh-CN.yml` 的 `packages.columns` 底下加入：

```yaml
      store: "店铺"
```

`config/locales/en.yml` 的 `packages.columns` 底下加入：

```yaml
      store: "Store"
```

- [ ] **Step 5: 表頭加入店鋪欄**

`app/views/packages/index.html.erb`，在 `<thead>` 裡的 `package_code` `<th>` **之前**插入：

```erb
              <% unless current_shopify_store %>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase"><%= t("packages.columns.store") %></th>
              <% end %>
```

並把空列的 colspan 從 `colspan="<%= bulk ? 9 : 8 %>"` 改為：

```erb
                <td colspan="<%= 8 + (bulk ? 1 : 0) + (current_shopify_store ? 0 : 1) %>" class="px-4 py-8 text-center text-sm text-gray-500"><%= t("packages.no_packages") %></td>
```

- [ ] **Step 6: 資料列加入店鋪欄**

`app/views/packages/_package_row.html.erb`，在 `package_code` 那個 `<td>` **之前**插入：

```erb
  <%# Only rendered in the all-stores view — in single-store mode the column
      would repeat the same name on every row for no information. %>
  <% unless current_shopify_store %>
    <td class="px-4 py-3 text-sm text-gray-700 align-top whitespace-nowrap"><%= package.shopify_store.name %></td>
  <% end %>
```

- [ ] **Step 7: 執行測試確認通過**

Run: `bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb`
Expected: PASS，0 failures。

若既有範例因預設變成「全部店鋪」而失敗，那是這個任務刻意造成的行為變更（規格第 3 節已確認）：修正該範例的期望值，不要為了讓舊測試通過而退回舊行為。

- [ ] **Step 8: Lint**

Run: `bin/rubocop app/controllers/admin_controller.rb`
Expected: no offenses。

- [ ] **Step 9: Commit**

```bash
git add app/controllers/admin_controller.rb app/views/packages/index.html.erb app/views/packages/_package_row.html.erb config/locales spec/requests/packages_spec.rb
git commit -m "$(cat <<'EOF'
feat(packing): allow the all-stores view on the packing list

Adds packages to STORE_ALL_ALLOWED_CONTROLLERS so the store switcher offers
"all", and shows a store column when more than one store is in view.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: 篩選列 UI、時間欄與建包時間

**Files:**
- Create: `app/helpers/packages_helper.rb`
- Create: `app/views/packages/_filter_bar.html.erb`
- Modify: `app/views/packages/index.html.erb`
- Modify: `app/views/packages/_package_row.html.erb`
- Modify: `app/views/packages/_order_info.html.erb`
- Modify: `app/views/packages/_pagination.html.erb`
- Modify: `config/locales/{zh-TW,zh-CN,en}.yml`
- Test: `spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: Task 3 的 `@countries` / `@country` / `@sort_column` / `@sort_direction`；Task 2 的 `PackageListQuery::SORT_COLUMNS`；Task 1 的 `Order#paid_at`；Task 4 的店鋪欄。
- Produces: `PackagesHelper#packages_list_path(overrides)` → `String`，Task 6 與 Task 7 不直接使用，但 `_pagination.html.erb` 依賴它。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/system/packages_spec.rb` 檔案結尾的最後一個 `end` 之前，加入：

```ruby
  describe "列表篩選與排序" do
    let!(:us_package) do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#7001",
                     ordered_at: 5.days.ago, paid_at: 5.days.ago)
      create(:package, shopify_store: store, order: order, aasm_state: "pending_review",
             number: 71, created_at: 5.days.ago,
             shipping_address_snapshot: { "country_code" => "US" })
    end

    let!(:ca_package) do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#7002",
                     ordered_at: 1.hour.ago, paid_at: 1.hour.ago)
      create(:package, shopify_store: store, order: order, aasm_state: "pending_review",
             number: 72, created_at: 1.hour.ago,
             shipping_address_snapshot: { "country_code" => "CA" })
    end

    it "narrows the list when a country pill is clicked, and restores it via 全部" do
      visit packages_path(state: "pending_review")

      expect(page).to have_content("PKS#7001")
      expect(page).to have_content("PKS#7002")

      click_link "#{I18n.t('shipping_rate_cards.countries.US')}"
      expect(page).to have_content("PKS#7001")
      expect(page).to have_no_content("PKS#7002")

      click_link I18n.t("packages.filters.all")
      expect(page).to have_content("PKS#7002")
    end

    it "sorts by order time and toggles direction on a second click" do
      visit packages_path(state: "pending_review")

      click_link I18n.t("packages.sort.ordered_at")
      expect(page.body.index("PKS#7002")).to be < page.body.index("PKS#7001")

      click_link I18n.t("packages.sort.ordered_at")
      expect(page.body.index("PKS#7001")).to be < page.body.index("PKS#7002")
    end

    it "shows the order and payment times on each row" do
      visit packages_path(state: "pending_review")

      expect(page).to have_content(I18n.t("packages.columns.ordered_at"))
      expect(page).to have_content(I18n.t("packages.columns.paid_at"))
    end
  end
```

同時在 `spec/requests/packages_spec.rb` 的 `describe "cross-store listing"` 區塊（Task 4 建立）內加入一個範例，釘住跨店鋪模式才附加時區縮寫的行為：

```ruby
      it "labels the timezone only when several stores share the list" do
        store.update!(timezone: "America/Los_Angeles")

        get packages_path
        cross_store_body = response.body

        get packages_path, params: { store_id: store.id }
        single_store_body = response.body

        expect(cross_store_body).to include(Time.current.in_time_zone("America/Los_Angeles").zone)
        expect(single_store_body).not_to include(Time.current.in_time_zone("America/Los_Angeles").zone)
      end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/system/packages_spec.rb -e "列表篩選與排序"`
Expected: FAIL —— 找不到國家膠囊連結（`Unable to find link`）。

- [ ] **Step 3: i18n 新增文案**

`config/locales/zh-TW.yml` 的 `packages:` 底下，`application_status:` 區塊之後加入：

```yaml
    filters:
      all: "全部"
      country: "國家區域"
      sort: "排序方式"
    sort:
      created_at: "按建包時間"
      ordered_at: "按下單時間"
      paid_at: "按付款時間"
```

同一檔案的 `packages.columns` 底下加入兩個鍵，並把既有的 `created_at` 文案改為「建包時間」（它不再是列表欄名，改為詳情頁的標籤，與排序項的用詞一致）：

```yaml
      created_at: "建包時間"
      ordered_at: "下單"
      paid_at: "付款"
```

`config/locales/zh-CN.yml` 對應加入：

```yaml
    filters:
      all: "全部"
      country: "国家区域"
      sort: "排序方式"
    sort:
      created_at: "按建包时间"
      ordered_at: "按下单时间"
      paid_at: "按付款时间"
```

```yaml
      created_at: "建包时间"
      ordered_at: "下单"
      paid_at: "付款"
```

`config/locales/en.yml` 對應加入：

```yaml
    filters:
      all: "All"
      country: "Country"
      sort: "Sort by"
    sort:
      created_at: "Packed time"
      ordered_at: "Order time"
      paid_at: "Payment time"
```

```yaml
      created_at: "Packed At"
      ordered_at: "Ordered"
      paid_at: "Paid"
```

- [ ] **Step 4: 建立 helper**

Create `app/helpers/packages_helper.rb`:

```ruby
module PackagesHelper
  # A list link that keeps the current filters and overrides only the given
  # params. request.query_parameters has STRING keys; merging symbol keys onto
  # it emits the same param twice and only works by Rack's last-one-wins
  # accident, so normalize to symbols first. nil overrides drop the param
  # (that is how the "all" pills clear a filter).
  #
  # Callers pass page: nil when changing a filter or sort — keeping the old page
  # would land the user on an empty page 3 of a now-shorter list.
  def packages_list_path(overrides)
    packages_path(request.query_parameters.symbolize_keys.merge(overrides).compact)
  end
end
```

- [ ] **Step 5: 建立篩選列 partial**

Create `app/views/packages/_filter_bar.html.erb`:

```erb
<%# 國家區域 + 排序方式。兩者都是純連結（Turbo Drive 負責導覽），不需要 Stimulus。
    國家清單只列出這個狀態下實際存在的國家，所以不會出現點了沒有結果的膠囊。 %>
<div class="bg-white rounded-lg border border-gray-200 px-4 py-3 mb-4 space-y-2">
  <% if countries.any? %>
    <div class="flex items-start gap-3">
      <span class="shrink-0 pt-1 text-sm text-gray-500"><%= t("packages.filters.country") %></span>
      <div class="flex flex-wrap gap-1.5">
        <%= link_to t("packages.filters.all"), packages_list_path(country: nil, page: nil),
              class: "px-2.5 py-1 text-sm rounded #{country.nil? ? 'bg-blue-600 text-white' : 'text-gray-700 hover:bg-gray-100'}" %>
        <% countries.each do |code| %>
          <%= link_to packages_list_path(country: code, page: nil),
                class: "px-2.5 py-1 text-sm rounded #{country == code ? 'bg-blue-600 text-white' : 'text-gray-700 hover:bg-gray-100'}" do %>
            <%= parcel_country_flag(code) %> <%= parcel_country_name(code) %>
          <% end %>
        <% end %>
      </div>
    </div>
  <% end %>

  <div class="flex items-start gap-3">
    <span class="shrink-0 pt-1 text-sm text-gray-500"><%= t("packages.filters.sort") %></span>
    <div class="flex flex-wrap gap-1.5">
      <% PackageListQuery::SORT_COLUMNS.each_key do |column| %>
        <% active = sort_column == column %>
        <%# Clicking the active column flips the direction; clicking another
            column starts it at desc (newest/largest first). %>
        <% next_direction = (active && sort_direction == "desc") ? "asc" : "desc" %>
        <%= link_to packages_list_path(sort_column: column, sort_direction: next_direction, page: nil),
              class: "px-2.5 py-1 text-sm rounded #{active ? 'bg-blue-600 text-white' : 'text-gray-700 hover:bg-gray-100'}" do %>
          <%= t("packages.sort.#{column}") %><% if active %> <%= sort_direction == "asc" ? "▲" : "▼" %><% end %>
        <% end %>
      <% end %>
    </div>
  </div>
</div>
```

- [ ] **Step 6: 在 index 掛上篩選列**

`app/views/packages/index.html.erb`，在 `applying_tracking` 的 `<nav>` 區塊（以 `<% end %>` 結束的那個 `<% if @state == "applying_tracking" %>`）之後、`<% bulk = ... %>` 之前插入：

```erb
  <%= render "packages/filter_bar", countries: @countries, country: @country,
        sort_column: @sort_column, sort_direction: @sort_direction %>
```

把表頭裡的建包時間欄改為時間欄——找到：

```erb
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase"><%= t("packages.columns.created_at") %></th>
```

換成：

```erb
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase"><%= t("packages.columns.ordered_at") %> / <%= t("packages.columns.paid_at") %></th>
```

- [ ] **Step 7: 資料列改為雙行時間**

`app/views/packages/_package_row.html.erb`，找到：

```erb
  <td class="px-4 py-3 text-sm text-gray-500 align-top whitespace-nowrap"><%= package.created_at.strftime("%Y-%m-%d %H:%M") %></td>
```

換成：

```erb
  <%# Times render in the STORE's timezone, matching the orders list. The old
      bare strftime here printed UTC, so the same order showed two different
      times on two pages. packages.shopify_store_id is NOT NULL and the
      association is eager-loaded by index, so this costs no extra query.

      In the all-stores view, stores in different zones each render their own
      local time while the sort runs on absolute time — the list would look
      mis-sorted. Appending the zone abbreviation there explains it. In
      single-store mode every row would repeat the same abbreviation, so it is
      left off. %>
  <% tz = package.shopify_store.active_timezone %>
  <% show_zone = current_shopify_store.nil? %>
  <td class="px-4 py-3 text-sm text-gray-500 align-top whitespace-nowrap">
    <% [ [ "ordered_at", package.order.ordered_at ], [ "paid_at", package.order.paid_at ] ].each do |label, value| %>
      <div>
        <%= t("packages.columns.#{label}") %>：
        <% if value %>
          <% local = value.in_time_zone(tz) %>
          <%= local.strftime("%Y-%m-%d %H:%M") %><%= " #{local.zone}" if show_zone %>
        <% else %>
          —
        <% end %>
      </div>
    <% end %>
  </td>
```

同一個檔案中，國家顯示也要跟 `PackageListQuery::COUNTRY_SQL` 一樣正規化，否則手動編輯存進的 `us` 會顯示成原始碼 `us`，而膠囊列顯示「美國」——同一筆資料兩種寫法。找到：

```erb
    <% country = package.shipping_address_snapshot["country_code"].presence ||
                 package.order.shopify_data&.dig("shipping_address", "country_code") %>
```

換成：

```erb
    <%# Normalized the same way PackageListQuery::COUNTRY_SQL normalizes it —
        #update_address accepts hand-typed country codes, so " us " is possible
        and must render as 美國, not as a raw code the filter pills don't match. %>
    <% country = (package.shipping_address_snapshot["country_code"].to_s.strip.presence ||
                  package.order.shopify_data&.dig("shipping_address", "country_code").to_s.strip.presence)&.upcase %>
```

- [ ] **Step 8: 詳情 modal 顯示建包時間**

建包時間讓出列表版面後仍須可查。`app/views/packages/_order_info.html.erb`，在 `<h4>` 所在的 `<div class="flex items-center justify-between mb-3">` 區塊結束的 `</div>` 之後插入：

```erb
  <p class="mb-3 text-xs text-gray-500">
    <%= t("packages.columns.created_at") %>：<%= package.created_at.in_time_zone(package.shopify_store.active_timezone).strftime("%Y-%m-%d %H:%M") %>
  </p>
```

- [ ] **Step 9: 分頁改用 helper**

`app/views/packages/_pagination.html.erb`，把三處 `packages_path(request.query_parameters.merge(page: X))` 改為 `packages_list_path(page: X)`：

```erb
        <%= link_to t("packages.prev"), packages_list_path(page: page - 1),
              class: "px-3 py-1 text-sm rounded-md border border-gray-300 bg-white text-gray-700 hover:bg-gray-50" %>
```

```erb
          <%= link_to p, packages_list_path(page: p),
                class: "px-3 py-1 text-sm rounded-md border #{p == page ? 'border-blue-500 bg-blue-50 text-blue-700 font-medium' : 'border-gray-300 bg-white text-gray-700 hover:bg-gray-50'}" %>
```

```erb
        <%= link_to t("packages.next"), packages_list_path(page: page + 1),
              class: "px-3 py-1 text-sm rounded-md border border-gray-300 bg-white text-gray-700 hover:bg-gray-50" %>
```

同時更新該檔開頭的註解第二句為：

```erb
<%# Pagination — mirrors app/views/parcels/_pagination.html.erb, reusing the
    shared pagination_range helper. Links go through packages_list_path so the
    current state/country/sort filters are preserved across pages. %>
```

- [ ] **Step 10: 執行測試確認通過**

Run: `bundle exec rspec spec/system/packages_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 11: 執行完整 packages 測試**

Run: `bundle exec rspec spec/requests/packages_spec.rb spec/models/package_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 12: Lint**

Run: `bin/rubocop app/helpers/packages_helper.rb`
Expected: no offenses。

- [ ] **Step 13: Commit**

```bash
git add app/helpers/packages_helper.rb app/views/packages config/locales spec/system/packages_spec.rb
git commit -m "$(cat <<'EOF'
feat(packing): add country and sort controls to the packing list

Country pills list only the countries actually present. Time column now shows
order and payment time in the store's timezone (it printed UTC before), and
packed time moves into the detail modal.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: 批量審核

**Files:**
- Modify: `config/routes.rb`（`resources :packages` 的 `collection do` 區塊）
- Modify: `app/controllers/packages_controller.rb`（新增 `submit_review_bulk` action 與 `list_filter_params` 私有方法）
- Modify: `app/views/packages/index.html.erb`
- Modify: `config/locales/{zh-TW,zh-CN,en}.yml`
- Test: `spec/requests/packages_spec.rb`、`spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: Task 3 的 `@country` / `@sort_column` / `@sort_direction`（用於表單 hidden fields）。
- Produces: `PackagesController#list_filter_params` → `Hash`（符號鍵，只含非空的 `:country` / `:sort_column` / `:sort_direction`），Task 7 會重用。路由 helper `submit_review_bulk_packages_path`。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/requests/packages_spec.rb` 檔案結尾的最後一個 `end` 之前加入：

```ruby
  describe "POST /packages/submit_review_bulk" do
    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_out user
      sign_in member
      member
    end

    it "advances every selected pending_review package" do
      second = create(:package, shopify_store: store, aasm_state: "pending_review", number: 81,
                      order: create(:order, customer: customer, shopify_store: store, name: "PKS#8001"))

      post submit_review_bulk_packages_path, params: { package_ids: [ review_package.id, second.id ] }

      expect(review_package.reload.aasm_state).to eq("pending_process")
      expect(second.reload.aasm_state).to eq("pending_process")
      expect(flash[:notice]).to include("2")
    end

    it "skips a package that is not pending_review" do
      post submit_review_bulk_packages_path, params: { package_ids: [ process_package.id ] }

      expect(process_package.reload.aasm_state).to eq("pending_process")
      expect(response).to redirect_to(packages_path(state: "pending_review"))
    end

    it "denies a member without package_review and transitions nothing" do
      sign_in_as_member_with("package_process")

      post submit_review_bulk_packages_path, params: { package_ids: [ review_package.id ] }

      expect(review_package.reload.aasm_state).to eq("pending_review")
      expect(response).to redirect_to(packages_path)
      expect(flash[:alert]).to eq(I18n.t("companies.no_permission"))
    end

    it "allows a member granted package_review" do
      sign_in_as_member_with("package_review")

      post submit_review_bulk_packages_path, params: { package_ids: [ review_package.id ] }

      expect(review_package.reload.aasm_state).to eq("pending_process")
    end

    it "ignores a package belonging to another company" do
      other_user = create(:user)
      other_store = create(:shopify_store, user: other_user, company: other_user.companies.first)
      other_customer = create(:customer, shopify_store: other_store)
      foreign = create(:package, shopify_store: other_store, aasm_state: "pending_review", number: 91,
                       order: create(:order, customer: other_customer, shopify_store: other_store))

      post submit_review_bulk_packages_path, params: { package_ids: [ foreign.id ] }

      expect(foreign.reload.aasm_state).to eq("pending_review")
    end

    it "carries the current filters back to the list" do
      post submit_review_bulk_packages_path,
           params: { package_ids: [ review_package.id ], country: "US",
                     sort_column: "paid_at", sort_direction: "asc" }

      expect(response).to redirect_to(
        packages_path(country: "US", sort_column: "paid_at", sort_direction: "asc", state: "pending_review")
      )
    end
  end
```

在 `spec/system/packages_spec.rb` 檔案結尾的最後一個 `end` 之前加入：

```ruby
  describe "批量審核" do
    it "advances the checked packages and empties the pending_review list" do
      visit packages_path(state: "pending_review")

      check_all = find("input[data-package-bulk-target='all']")
      check_all.check

      click_button I18n.t("packages.review.bulk_button")

      expect(page).to have_content(I18n.t("packages.states.pending_review"))
      expect(page).to have_no_content("PKS#3001")
    end
  end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/requests/packages_spec.rb -e "submit_review_bulk"`
Expected: FAIL，`undefined local variable or method 'submit_review_bulk_packages_path'`。

- [ ] **Step 3: 新增路由**

`config/routes.rb` 的 `resources :packages` 的 `collection do` 區塊，在 `post :sync` 之後加入：

```ruby
        post :submit_review_bulk
```

- [ ] **Step 4: 新增 i18n**

`config/locales/zh-TW.yml` 的 `packages:` 底下（`apply:` 區塊之前）加入：

```yaml
    review:
      bulk_button: "批量審核"
      bulk_result: "已審核 %{reviewed} 個，跳過 %{skipped} 個"
```

`config/locales/zh-CN.yml`：

```yaml
    review:
      bulk_button: "批量审核"
      bulk_result: "已审核 %{reviewed} 个，跳过 %{skipped} 个"
```

`config/locales/en.yml`：

```yaml
    review:
      bulk_button: "Bulk review"
      bulk_result: "Reviewed %{reviewed}, skipped %{skipped}"
```

- [ ] **Step 5: 新增 controller action**

在 `app/controllers/packages_controller.rb` 的 `ship_bulk` 方法之後、`sync_shipment` 之前插入：

```ruby
  # Bulk review from the pending_review list (gated on package_review, the same
  # permission that guards REVIEW_EVENTS in #transition). Per-package isolation
  # mirrors apply_tracking_bulk/ship_bulk: a package whose state raced between
  # the scope query and submit_review! (AASM::InvalidTransition) is counted as
  # skipped rather than aborting the rest of the batch.
  def submit_review_bulk
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_review?

    ids = Array(params[:package_ids]).map(&:to_s)
    reviewed = 0
    skipped = 0
    scoped_packages.where(id: ids, aasm_state: "pending_review").find_each do |package|
      package.submit_review!
      reviewed += 1
    rescue AASM::InvalidTransition, ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[ReviewBulk] Package##{package.id}: #{e.class}: #{e.message}")
      skipped += 1
    end
    redirect_to packages_path(list_filter_params.merge(state: "pending_review")),
                notice: t("packages.review.bulk_result", reviewed: reviewed, skipped: skipped)
  end
```

在 `private` 之後（`ship_package` 方法之前）加入：

```ruby
  # The list filters, carried back through a bulk action's redirect. Without
  # this, one click on a bulk button silently resets the user's country/sort
  # selection. Values are re-validated by PackageListQuery on the way back in,
  # so this only has to move them.
  def list_filter_params
    params.permit(:country, :sort_column, :sort_direction).to_h.compact_blank.symbolize_keys
  end
```

- [ ] **Step 6: view 納入批量審核**

`app/views/packages/index.html.erb`，把 `bulk` 相關的四行：

```erb
  <% bulk = %w[pending_process pending_label].include?(@state) %>
  <% bulk_url = @state == "pending_label" ? labels_packages_path : apply_tracking_bulk_packages_path %>
  <% bulk_label = @state == "pending_label" ? t("packages.label.bulk_button") : t("packages.apply.bulk_button") %>
  <% bulk_html = @state == "pending_label" ? { id: "packages-bulk-form", target: "_blank" } : { id: "packages-bulk-form" } %>
```

換成：

```erb
  <% bulk = %w[pending_review pending_process pending_label].include?(@state) %>
  <%
    bulk_url, bulk_label =
      case @state
      when "pending_label"  then [ labels_packages_path, t("packages.label.bulk_button") ]
      when "pending_review" then [ submit_review_bulk_packages_path, t("packages.review.bulk_button") ]
      else                       [ apply_tracking_bulk_packages_path, t("packages.apply.bulk_button") ]
      end
  %>
  <% bulk_html = @state == "pending_label" ? { id: "packages-bulk-form", target: "_blank" } : { id: "packages-bulk-form" } %>
```

並在 `<% if bulk %>` 區塊內、`<div data-package-bulk-target="bar" ...>` 之前插入 hidden fields，讓每個批量 POST 都帶著目前的篩選：

```erb
      <%= hidden_field_tag :country, @country %>
      <%= hidden_field_tag :sort_column, @sort_column %>
      <%= hidden_field_tag :sort_direction, @sort_direction %>
```

- [ ] **Step 7: 執行測試確認通過**

Run: `bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 8: Lint 與安全掃描**

Run: `bin/rubocop app/controllers/packages_controller.rb config/routes.rb && bin/brakeman --no-pager`
Expected: rubocop no offenses；brakeman 0 warnings。

- [ ] **Step 9: Commit**

```bash
git add config/routes.rb app/controllers/packages_controller.rb app/views/packages/index.html.erb config/locales spec/requests/packages_spec.rb spec/system/packages_spec.rb
git commit -m "$(cat <<'EOF'
feat(packing): bulk review on the pending_review list

Gated on package_review, with the same per-package isolation as the existing
bulk actions, and the current filters carried back through the redirect.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: 既有批量操作保留篩選

`apply_tracking_bulk` 與 `ship_bulk` 的 redirect 寫死 `packages_path(state: ...)`，在其他狀態頁使用批量功能一樣會把使用者的篩選洗掉。Task 6 已備妥 `list_filter_params` 與表單 hidden fields，這裡把它套用到這兩個既有 action。

**Files:**
- Modify: `app/controllers/packages_controller.rb`（`apply_tracking_bulk` 與 `ship_bulk` 的 redirect）
- Test: `spec/requests/packages_spec.rb`

**Interfaces:**
- Consumes: Task 6 的 `list_filter_params`。
- Produces: 無新介面。

- [ ] **Step 1: 寫失敗的測試**

在 `spec/requests/packages_spec.rb` 中既有的 `describe "POST /packages/apply_tracking_bulk"`（若名稱不同，用 `grep -n "apply_tracking_bulk" spec/requests/packages_spec.rb` 找到對應區塊）內加入：

```ruby
    it "carries the current filters back to the list" do
      post apply_tracking_bulk_packages_path,
           params: { package_ids: [ process_package.id ], country: "US", sort_column: "ordered_at" }

      expect(response).to redirect_to(
        packages_path(country: "US", sort_column: "ordered_at", state: "pending_process")
      )
    end
```

在既有的 `describe "POST /packages/ship_bulk"` 區塊內加入：

```ruby
    it "carries the current filters back to the list" do
      post ship_bulk_packages_path,
           params: { package_ids: [], country: "US", sort_column: "ordered_at" }

      expect(response).to redirect_to(
        packages_path(country: "US", sort_column: "ordered_at", state: "pending_label")
      )
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/requests/packages_spec.rb -e "carries the current filters back to the list"`
Expected: FAIL —— 兩個新範例的 redirect 期望不符（實際 redirect 不含 country/sort_column）。Task 6 的同名範例仍會通過。

- [ ] **Step 3: 套用 list_filter_params**

`app/controllers/packages_controller.rb` 的 `apply_tracking_bulk` 結尾：

```ruby
    redirect_to packages_path(list_filter_params.merge(state: "pending_process")), notice: t("packages.apply.bulk_result", applied: applied, skipped: skipped)
```

`ship_bulk` 結尾：

```ruby
    redirect_to packages_path(list_filter_params.merge(state: "pending_label")), notice: t("packages.ship.bulk_result", shipped: shipped)
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/requests/packages_spec.rb`
Expected: PASS，0 failures。

- [ ] **Step 5: 全套件驗證**

Run: `bundle exec rspec`
Expected: PASS，0 failures，且 SimpleCov 行覆蓋率 ≥ 95%。若覆蓋率未達標，找出未覆蓋的新程式碼行並補測試——不要調低門檻。

- [ ] **Step 6: 完整 CI 檢查**

Run: `bin/rubocop && bin/brakeman --no-pager && bin/bundler-audit && bin/importmap audit`
Expected: 全部乾淨。

- [ ] **Step 7: Commit**

```bash
git add app/controllers/packages_controller.rb spec/requests/packages_spec.rb
git commit -m "$(cat <<'EOF'
fix(packing): keep list filters across the existing bulk actions

apply_tracking_bulk and ship_bulk hardcoded the redirect, so one bulk click
reset the user's country and sort selection.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## 完成後

全部任務完成、`bundle exec rspec` 全綠、CI 檢查乾淨後，使用 `superpowers:finishing-a-development-branch` skill 決定如何整合（本專案流程為：feature branch → PR 到 `staging`）。
