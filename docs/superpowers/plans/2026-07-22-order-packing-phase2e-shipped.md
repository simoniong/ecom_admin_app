# 訂單打包 Phase 2E — 已交運 (shipped / 發貨) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pending_label` 包裹「發貨」→ `ship`（→shipped，永遠執行）；per-店鋪開關開啟時，背景 job 額外做 華磊标记发货 + 17Track 註冊 + Shopify 逐包裹回寫，含分步冪等、per-order 序列化、重試前對帳。

**Architecture:** 三個外部整合 service（`Raydo#mark_shipped`、`ShopifyFulfillmentService`、既有 `TrackingService`）由 `PackageShipmentSyncer` 編排；`PackageShipSyncJob` 非同步執行（只在店鋪開關開時 enqueue）；`ship` 動作在 `with_lock` 內原子轉狀態。Shopify 用官方 `ShopifyAPI::Clients::Graphql::Admin` 跑 `fulfillmentCreate`（需新增 OAuth 寫入 scope + 兩店 reauth）。

**Tech Stack:** Rails 8.1、AASM、Solid Queue、HTTParty、shopify_api gem（GraphQL）、Hotwire、Tailwind、PostgreSQL(UUID)、RSpec + FactoryBot + WebMock。

## Global Constraints

- 所有 table id 用 UUID。測試 RSpec + FactoryBot，**不 mock DB、打真 DB、95%+ coverage**；外部 HTTP 一律 **WebMock**（華磊/17Track/Shopify graphql.json 皆 stub）。每功能 model/service + request + system。
- 絕不 commit 到 `staging`/`main`；在 `feature/order-packing-phase2e-ship`（從 origin/staging 切）。推送 `git push -u origin feature/order-packing-phase2e-ship`。
- 印面單/發貨無關：發貨只做 ship + （開關開時）三副作用。ship **永遠轉狀態**、失敗維持 shipped。
- 權限：`ship`/`ship_bulk`/`sync_shipment` gate `current_membership&.package_shipping?`；店鋪開關 owner-gated。先 scoped（跨公司 404/過濾）。失敗 redirect/422，**絕不 500**。
- 外部 API 錯誤：只露 exception class（沿用 raydo.rb 紀律）；`ship_sync_message` 不外露原始 carrier 字串/憑證。
- Shopify：用 **`fulfillmentCreate`**（非 deprecated V2）；line item ID 需 **REST 數字 ↔ GID 正規化**；同訂單回寫 **per-order 序列化鎖**；重試前 **對帳既有 fulfillment**（不盲建）。
- Ruby toolchain：PATH 前置 `/home/simon/.rubies/ruby-3.4.7/bin`。單檔 rspec 因 SimpleCov 可能 exit 2（看「N examples, 0 failures」）。
- 17Track `register`：非 2xx 才 raise；已註冊者回 200（accepted 不含它但不 raise）——**不 raise 即視為成功**。
- 溝通用繁體中文；程式碼/路徑/commit 英文。Spec：`docs/superpowers/specs/2026-07-22-order-packing-phase2e-shipped-design.md`。

---

## File Structure

- **Migration**（新增）：store `shipping_sync_enabled` + packages 6 欄 + 索引/部分唯一。
- **`app/models/shopify_store.rb`**（改）：`fulfillment_write_scope?`。
- **`app/models/package.rb`**（改）：`ship_sync_status` inclusion 驗證。
- **`app/controllers/shopify_oauth_controller.rb`**（改）：OAuth scope 加寫入。
- **`app/services/fulfillment_service/raydo.rb`**（改）：`mark_shipped`。
- **`app/services/shopify_fulfillment_service.rb`**（新增）：GID 正規化 + fulfillmentOrders 查詢 + `fulfillmentCreate` + reconcile。
- **`app/services/package_shipment_syncer.rb`**（新增）：編排三步。
- **`app/jobs/package_ship_sync_job.rb`**（新增）。
- **`app/controllers/packages_controller.rb`**（改）：`ship`/`ship_bulk`/`sync_shipment` + `ship_package` helper。
- **`app/controllers/shopify_stores_controller.rb`**（改）：開關分支 + permit。
- **`config/routes.rb`**（改）。
- **Views**：`_actions.html.erb`、`index.html.erb`（批量一般化）、店鋪設定頁（開關 + reauth 提示）、i18n。
- **Specs**：model/service/job/request/system。

**共用測試前置**（各 spec 沿用）：
```ruby
let(:user)     { create(:user) }
let(:company)  { user.companies.first }
let(:store)    { create(:shopify_store, user: user, company: company, package_prefix: "XMBDE", package_number_start: 2013094,
                        shop_domain: "s.myshopify.com", access_token: "shpat_x", scopes: "read_all_orders,write_merchant_managed_fulfillment_orders") }
let(:account)  { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089", customer_id: "6581", customer_userid: "6901") }
let(:channel)  { create(:logistics_channel, logistics_account: account, product_id: "P1", shopify_carrier_name: "YunExpress", tracking_url_template: "https://t.17track.net/en#nums=#TrackingNumber#") }

def shipped_ready_package(number: 900)
  order = create(:order, customer: customer, shopify_store: store, shopify_order_id: 5000 + number)
  pkg = create(:package, shopify_store: store, order: order, number: number, aasm_state: "pending_label",
               logistics_channel: channel, raydo_order_id: "R#{number}", tracking_number: "TN#{number}", carrier: "YunExpress")
  oli = create(:order_line_item, order: order, shopify_line_item_id: 6000 + number, quantity: 2)
  create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 2, refunded_quantity: 0,
         customs_name_en: "Art", customs_name_zh: "画", declared_value_usd: 10, customs_weight_grams: 100)
  pkg
end
```

---

### Task 1: Migration + model 驗證 + `ShopifyStore#fulfillment_write_scope?`

**Files:** migration（新增）；`db/schema.rb`；`app/models/shopify_store.rb`；`app/models/package.rb`；`spec/models/shopify_store_spec.rb`；`spec/models/package_spec.rb`

**Interfaces:**
- Produces: `shopify_stores.shipping_sync_enabled`(bool default false null:false)；packages `shipped_at`/`ship_sync_status`(default "none" null:false)/`ship_sync_message`(text)/`carrier_marked_at`/`tracking_registered_at`/`shopify_fulfillment_id`；`index packages.ship_sync_status`；`unique partial index packages.shopify_fulfillment_id`；`Package` validates ship_sync_status inclusion；`ShopifyStore#fulfillment_write_scope?` → Boolean。

- [ ] **Step 1: Write the failing tests**

`spec/models/shopify_store_spec.rb`：
```ruby
describe "#shipping_sync_enabled / #fulfillment_write_scope?" do
  it "defaults shipping_sync_enabled to false" do
    expect(create(:shopify_store).shipping_sync_enabled).to be(false)
  end
  it "detects the fulfillment write scope in scopes" do
    expect(build(:shopify_store, scopes: "read_all_orders,write_merchant_managed_fulfillment_orders").fulfillment_write_scope?).to be(true)
    expect(build(:shopify_store, scopes: "read_all_orders").fulfillment_write_scope?).to be(false)
    expect(build(:shopify_store, scopes: nil).fulfillment_write_scope?).to be(false)
  end
end
```
`spec/models/package_spec.rb`：
```ruby
describe "ship_sync_status" do
  it "defaults to none and validates inclusion" do
    order = create(:order); pkg = create(:package, shopify_store: order.shopify_store, order: order)
    expect(pkg.ship_sync_status).to eq("none")
    pkg.ship_sync_status = "bogus"
    expect(pkg).not_to be_valid
  end
end
describe "shopify_fulfillment_id partial unique index" do
  it "rejects a duplicate non-null shopify_fulfillment_id" do
    o1 = create(:order); o2 = create(:order, shopify_store: o1.shopify_store)
    create(:package, shopify_store: o1.shopify_store, order: o1, number: 1, shopify_fulfillment_id: "gid://shopify/Fulfillment/1")
    dup = build(:package, shopify_store: o1.shopify_store, order: o2, number: 2, shopify_fulfillment_id: "gid://shopify/Fulfillment/1")
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/models/shopify_store_spec.rb spec/models/package_spec.rb -e ship_sync -e fulfillment_write -e shipping_sync -e "partial unique"`
Expected: FAIL — undefined method / no such column.

- [ ] **Step 3: Migration**

`bin/rails g migration AddShipmentSyncFieldsToPackagesAndStores`：
```ruby
class AddShipmentSyncFieldsToPackagesAndStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :shipping_sync_enabled, :boolean, null: false, default: false

    add_column :packages, :shipped_at, :datetime
    add_column :packages, :ship_sync_status, :string, null: false, default: "none"
    add_column :packages, :ship_sync_message, :text
    add_column :packages, :carrier_marked_at, :datetime
    add_column :packages, :tracking_registered_at, :datetime
    add_column :packages, :shopify_fulfillment_id, :string

    add_index :packages, :ship_sync_status
    add_index :packages, :shopify_fulfillment_id, unique: true, where: "shopify_fulfillment_id IS NOT NULL",
              name: "index_packages_on_shopify_fulfillment_id_unique"
  end
end
```

- [ ] **Step 4: Model edits**

`app/models/package.rb`（與既有 `application_status` inclusion 並列）：
```ruby
  validates :ship_sync_status, inclusion: { in: %w[none pending succeeded failed] }
```
`app/models/shopify_store.rb`：
```ruby
  FULFILLMENT_WRITE_SCOPE = "write_merchant_managed_fulfillment_orders"

  def fulfillment_write_scope?
    scopes.to_s.split(",").map(&:strip).include?(FULFILLMENT_WRITE_SCOPE)
  end
```

- [ ] **Step 5: Migrate + run**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rails db:migrate && bin/rails db:test:prepare && bundle exec rspec spec/models/shopify_store_spec.rb spec/models/package_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**
```bash
git add db/migrate db/schema.rb app/models/package.rb app/models/shopify_store.rb spec/models
git commit -m "feat(packing): shipment-sync fields on packages + store toggle + fulfillment_write_scope?"
```

---

### Task 2: OAuth scope 加寫入 fulfillment

**Files:** `app/controllers/shopify_oauth_controller.rb:36`；`spec/requests/shopify_oauth_spec.rb`（或既有 oauth spec）

**Interfaces:** Produces: OAuth authorize 請求 scope 含 `write_merchant_managed_fulfillment_orders`。

- [ ] **Step 1: Write the failing test**

OAuth 進入點是 `POST shopify/auth`（route helper `shopify_auth_path`，`ShopifyOauthController#auth`，該 action 組出 Shopify authorize URL 並 redirect，scope 字串硬編在 line 36）。先讀 `app/controllers/shopify_oauth_controller.rb#auth` 確認它需要的 params（shop domain 等）與是否需登入。在 `spec/requests/shopify_oauth_spec.rb`（若不存在則新建）新增一個驅動 `auth` 的測試，斷言 redirect 到 Shopify 的 authorize URL 且**包含新 scope 字串**：
```ruby
it "requests the fulfillment write scope in the authorize redirect" do
  # 對齊 auth action 實際需要的觸發方式（登入 + shop 參數 + 任何 pending session 設定）。
  post shopify_auth_path, params: { shop: "newshop.myshopify.com" }
  expect(response).to have_http_status(:redirect)
  expect(response.location).to include("write_merchant_managed_fulfillment_orders")
end
```
> 若 `auth` 需要登入或特定 params/session，照 action 內容補齊（讀該 action）。目標只驗新 scope 出現在 authorize redirect URL。若驅動整個 action 過於依賴外部設定，退而求其次：把 line 36 的 scope 抽成常數 `ShopifyOauthController::OAUTH_SCOPES` 並斷言常數含新 scope（同樣達到「scope 已加入」的驗證）。

- [ ] **Step 2: Run to verify it fails**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/shopify_oauth_spec.rb -e "fulfillment write scope"`
Expected: FAIL — scope 不在 URL。

- [ ] **Step 3: Add the scope**

`app/controllers/shopify_oauth_controller.rb:36`：
```ruby
    scopes = "read_products,read_customers,read_all_orders,read_fulfillments,read_analytics,write_webhooks,write_merchant_managed_fulfillment_orders"
```

- [ ] **Step 4: Run to verify it passes**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/shopify_oauth_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add app/controllers/shopify_oauth_controller.rb spec/requests/shopify_oauth_spec.rb
git commit -m "feat(shopify): request write_merchant_managed_fulfillment_orders scope (reauth needed)"
```

---

### Task 3: `FulfillmentService::Raydo#mark_shipped`

**Files:** `app/services/fulfillment_service/raydo.rb`；`spec/services/fulfillment_service/raydo_spec.rb`

**Interfaces:** Produces: `Raydo#mark_shipped(order_customerinvoicecode) → true`；失敗/無法辨識回應 → raise `FulfillmentService::Error`。

- [ ] **Step 1: Write the failing tests**

```ruby
describe "#mark_shipped" do
  let(:account) { create(:logistics_account, url1_base: "http://raydo.test:8082", customer_id: "6581", customer_userid: "6901") }

  it "marks shipped and returns true on an ack response" do
    stub_request(:get, "http://raydo.test:8082/postOrderApi.htm").
      with(query: { customer_id: "6581", order_customerinvoicecode: "XMBDE2013094" }).
      to_return(body: { ack: "true" }.to_json, headers: { "Content-Type" => "application/json" })
    expect(described_class.new(account).mark_shipped("XMBDE2013094")).to be(true)
  end

  it "raises on an unrecognized/non-ack response (conservative)" do
    stub_request(:get, "http://raydo.test:8082/postOrderApi.htm").with(query: hash_including({})).
      to_return(body: "<html>error</html>", headers: { "Content-Type" => "text/html" })
    expect { described_class.new(account).mark_shipped("X") }.to raise_error(FulfillmentService::Error)
  end

  it "raises on HTTP error" do
    stub_request(:get, "http://raydo.test:8082/postOrderApi.htm").with(query: hash_including({})).to_return(status: 500, body: "e")
    expect { described_class.new(account).mark_shipped("X") }.to raise_error(FulfillmentService::Error, /HTTP 500/)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/fulfillment_service/raydo_spec.rb -e mark_shipped`
Expected: FAIL — undefined method.

- [ ] **Step 3: Implement**

在 `Raydo` public 方法區加（沿用既有私有 `get`——它用 url1_base + GBK/單引號解析）：
```ruby
    # GET url1/postOrderApi.htm?customer_id=&order_customerinvoicecode=  (标记发货)
    # Raydo does NOT document the response for this endpoint, so we are
    # conservative: success only when the parsed body is a Hash whose ack/status
    # indicates success. Any other (HTML error page, unparseable) → raise, so a
    # retry never blindly repeats a possibly-successful carrier side effect.
    def mark_shipped(order_customerinvoicecode)
      res = get("/postOrderApi.htm", customer_id: @account.customer_id, order_customerinvoicecode: order_customerinvoicecode)
      ok = res.is_a?(Hash) && (res["ack"].to_s == "true" || res["status"].to_s == "true" || res["status"].to_s == "200")
      raise FulfillmentService::Error, "Raydo mark_shipped unrecognized response" unless ok

      true
    end
```
> `get` 已把非 2xx / 連線錯誤 raise 成 `FulfillmentService::Error`（class-only）。此處只加「回應辨識」保守判斷。實際對接時若華磊回應鍵名不同，調整 `ok` 判斷（spec 也一併更新）。

- [ ] **Step 4: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/fulfillment_service/raydo_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add app/services/fulfillment_service/raydo.rb spec/services/fulfillment_service/raydo_spec.rb
git commit -m "feat(packing): Raydo#mark_shipped (标记发货, conservative success)"
```

---

### Task 4: `ShopifyFulfillmentService`（逐包裹回寫 + 對帳）

**Files:** `app/services/shopify_fulfillment_service.rb`（新增）；`spec/services/shopify_fulfillment_service_spec.rb`

**Interfaces:**
- Produces: `ShopifyFulfillmentService.new(package).call → String`（fulfillment GID）；失敗 raise `ShopifyFulfillmentService::Error`；缺 open fulfillment order / 缺 scope / 對不到 line item → raise（安全訊息）。內部先 reconcile（既有 fulfillment 帶同 tracking_number → 回傳其 id，不重建）。

- [ ] **Step 1: Write the failing tests**

`spec/services/shopify_fulfillment_service_spec.rb`（用 §File Structure 的 `shipped_ready_package`；WebMock stub graphql.json，比照 `spec/services/shopify_analytics_service_spec.rb` 的 GraphQL stub 慣例——POST `https://s.myshopify.com/admin/api/2024-10/graphql.json`，用 body 內含的 query 字串或 `hash_including` 判斷）：
```ruby
require "rails_helper"

RSpec.describe ShopifyFulfillmentService do
  # (共用前置 let :user/company/store/account/channel + shipped_ready_package)
  let(:gql) { "https://s.myshopify.com/admin/api/2024-10/graphql.json" }

  def stub_gql(&resp)
    stub_request(:post, gql).to_return { |req| { body: resp.call(req).to_json, headers: { "Content-Type" => "application/json" } } }
  end

  it "creates a fulfillment for the package's line items and returns its id" do
    pkg = shipped_ready_package
    calls = []
    stub_request(:post, gql).to_return do |req|
      body = JSON.parse(req.body); calls << body
      if body["query"].include?("fulfillments(") # reconcile query → none
        { body: { data: { order: { fulfillments: [] } } }.to_json }
      elsif body["query"].include?("fulfillmentOrders")
        { body: { data: { order: { fulfillmentOrders: { edges: [ { node: { id: "gid://shopify/FulfillmentOrder/1", status: "OPEN",
            lineItems: { edges: [ { node: { id: "gid://shopify/FulfillmentOrderLineItem/9", remainingQuantity: 2,
              lineItem: { id: "gid://shopify/LineItem/#{6000 + 900}" } } } ] } } } ] } } } }.to_json }
      else # fulfillmentCreate
        { body: { data: { fulfillmentCreate: { fulfillment: { id: "gid://shopify/Fulfillment/77" }, userErrors: [] } } }.to_json }
      end
    end
    expect(described_class.new(pkg).call).to eq("gid://shopify/Fulfillment/77")
    create_call = calls.find { |c| c["query"].include?("fulfillmentCreate") }
    fo = create_call.dig("variables", "fulfillment", "lineItemsByFulfillmentOrder").first
    expect(fo["fulfillmentOrderId"]).to eq("gid://shopify/FulfillmentOrder/1")
    expect(fo["fulfillmentOrderLineItems"]).to eq([ { "id" => "gid://shopify/FulfillmentOrderLineItem/9", "quantity" => 2 } ])
    expect(create_call.dig("variables", "fulfillment", "trackingInfo")).to include("number" => "TN900", "company" => "YunExpress")
    expect(create_call.dig("variables", "fulfillment", "notifyCustomer")).to be(true)
  end

  it "reconciles: adopts an existing fulfillment with the same tracking number (no re-create)" do
    pkg = shipped_ready_package
    stub_request(:post, gql).to_return do |req|
      body = JSON.parse(req.body)
      raise "should not create" if body["query"].include?("fulfillmentCreate")
      { body: { data: { order: { fulfillments: [ { id: "gid://shopify/Fulfillment/55", trackingInfo: [ { number: "TN900" } ] } ] } } }.to_json }
    end
    expect(described_class.new(pkg).call).to eq("gid://shopify/Fulfillment/55")
  end

  it "raises on userErrors" do
    pkg = shipped_ready_package
    stub_request(:post, gql).to_return do |req|
      body = JSON.parse(req.body)
      if body["query"].include?("fulfillments(")
        { body: { data: { order: { fulfillments: [] } } }.to_json }
      elsif body["query"].include?("fulfillmentOrders")
        { body: { data: { order: { fulfillmentOrders: { edges: [ { node: { id: "gid://shopify/FulfillmentOrder/1", status: "OPEN",
            lineItems: { edges: [ { node: { id: "gid://shopify/FulfillmentOrderLineItem/9", remainingQuantity: 2,
              lineItem: { id: "gid://shopify/LineItem/6900" } } } ] } } } ] } } } }.to_json }
      else
        { body: { data: { fulfillmentCreate: { fulfillment: nil, userErrors: [ { field: [ "fulfillment" ], message: "cannot" } ] } } }.to_json }
      end
    end
    expect { described_class.new(pkg).call }.to raise_error(ShopifyFulfillmentService::Error, /cannot/)
  end

  it "raises when there is no open fulfillment order" do
    pkg = shipped_ready_package
    stub_request(:post, gql).to_return do |req|
      body = JSON.parse(req.body)
      if body["query"].include?("fulfillments(")
        { body: { data: { order: { fulfillments: [] } } }.to_json }
      else
        { body: { data: { order: { fulfillmentOrders: { edges: [] } } } }.to_json }
      end
    end
    expect { described_class.new(pkg).call }.to raise_error(ShopifyFulfillmentService::Error, /no open fulfillment/i)
  end

  it "raises when the store lacks the fulfillment write scope" do
    pkg = shipped_ready_package
    pkg.shopify_store.update!(scopes: "read_all_orders")
    expect { described_class.new(pkg).call }.to raise_error(ShopifyFulfillmentService::Error, /scope|reauth/i)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/shopify_fulfillment_service_spec.rb`
Expected: FAIL — `uninitialized constant ShopifyFulfillmentService`.

- [ ] **Step 3: Implement**

`app/services/shopify_fulfillment_service.rb`：
```ruby
# Creates ONE Shopify fulfillment for a single package's line items (split
# orders → one fulfillment per package), carrying its tracking number, and
# notifying the customer. Reconciles first (a prior ambiguous create that
# timed out): if a fulfillment already carries this package's tracking number,
# adopt its id instead of re-creating. Line item ids are normalized (stored REST
# numeric id → GID) before matching Shopify's GID-based fulfillmentOrderLineItems.
# See docs/superpowers/specs/2026-07-22-order-packing-phase2e-shipped-design.md.
class ShopifyFulfillmentService
  class Error < StandardError; end

  API_VERSION = "2024-10"

  def initialize(package)
    @package = package
    @store = package.shopify_store
    @order = package.order
  end

  def call
    raise Error, "store is missing the fulfillment write scope — reauthorize" unless @store.fulfillment_write_scope?

    existing = reconcile_existing
    return existing if existing

    fo = open_fulfillment_order_line_items
    raise Error, "no open fulfillment order for this order" if fo.nil? || fo[:line_items].empty?

    create_fulfillment(fo)
  end

  private

  def client
    @client ||= begin
      session = ShopifyAPI::Auth::Session.new(shop: @store.shop_domain, access_token: @store.access_token)
      ShopifyAPI::Clients::Graphql::Admin.new(session: session)
    end
  end

  def order_gid
    "gid://shopify/Order/#{@order.shopify_order_id}"
  end

  # Map this package's shippable items' REST line item ids to GIDs.
  def wanted_line_item_gids
    @package.shippable_items.each_with_object({}) do |item, h|
      next if item.order_line_item&.shopify_line_item_id.blank?

      qty = item.quantity - item.refunded_quantity
      next if qty <= 0

      h["gid://shopify/LineItem/#{item.order_line_item.shopify_line_item_id}"] = qty
    end
  end

  # Reconcile: has a fulfillment with this package's tracking number already been created?
  def reconcile_existing
    q = <<~GQL
      query($id: ID!) {
        order(id: $id) {
          fulfillments(first: 30) { id trackingInfo { number } }
        }
      }
    GQL
    data = run(q, id: order_gid).dig("order", "fulfillments") || []
    hit = data.find { |f| Array(f["trackingInfo"]).any? { |t| t["number"] == @package.tracking_number } }
    hit && hit["id"]
  end

  def open_fulfillment_order_line_items
    q = <<~GQL
      query($id: ID!) {
        order(id: $id) {
          fulfillmentOrders(first: 20, query: "status:open") {
            edges { node { id status
              lineItems(first: 50) { edges { node { id remainingQuantity lineItem { id } } } } } }
          }
        }
      }
    GQL
    wanted = wanted_line_item_gids
    (run(q, id: order_gid).dig("order", "fulfillmentOrders", "edges") || []).each do |edge|
      node = edge["node"]
      lines = (node.dig("lineItems", "edges") || []).filter_map do |le|
        n = le["node"]
        gid = n.dig("lineItem", "id")
        next unless wanted.key?(gid)

        qty = [ wanted[gid], n["remainingQuantity"].to_i ].min
        next if qty <= 0

        { id: n["id"], quantity: qty }
      end
      return { fulfillment_order_id: node["id"], line_items: lines } if lines.any?
    end
    nil
  end

  def create_fulfillment(fo)
    m = <<~GQL
      mutation fulfillmentCreate($fulfillment: FulfillmentInput!) {
        fulfillmentCreate(fulfillment: $fulfillment) {
          fulfillment { id }
          userErrors { field message }
        }
      }
    GQL
    vars = {
      fulfillment: {
        lineItemsByFulfillmentOrder: [ { fulfillmentOrderId: fo[:fulfillment_order_id], fulfillmentOrderLineItems: fo[:line_items] } ],
        trackingInfo: { number: @package.tracking_number, company: @package.logistics_channel&.shopify_carrier_name, url: tracking_url },
        notifyCustomer: true
      }
    }
    res = run(m, **vars)["fulfillmentCreate"] || {}
    errors = res["userErrors"] || []
    raise Error, errors.map { |e| e["message"] }.join("; ").presence || "fulfillmentCreate failed" if errors.any?

    res.dig("fulfillment", "id") or raise Error, "fulfillmentCreate returned no id"
  end

  def tracking_url
    @package.logistics_channel&.tracking_url_template.to_s.gsub("#TrackingNumber#", @package.tracking_number.to_s)
  end

  # Runs a GraphQL op; returns response.body["data"] (Hash). Raises Error on
  # transport failure or top-level GraphQL errors (message-only, safe).
  def run(query, **variables)
    resp = client.query(query: query, variables: variables)
    body = resp.body || {}
    raise Error, "shopify graphql error" if (body["errors"] || []).any?

    body["data"] || {}
  rescue ShopifyAPI::Errors::HttpResponseError => e
    raise Error, "shopify http error (#{e.code})"
  rescue => e
    raise Error, "shopify request failed (#{e.class})"
  end
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/shopify_fulfillment_service_spec.rb`
Expected: PASS. （若 `ShopifyAPI::Clients::Graphql::Admin` 在 test 需 `ShopifyAPI::Context.setup`——比照 `spec/services/shopify_analytics_service_spec.rb` 的既有設定；沿用該檔的 context/session 前置。）

- [ ] **Step 5: Commit**
```bash
git add app/services/shopify_fulfillment_service.rb spec/services/shopify_fulfillment_service_spec.rb
git commit -m "feat(packing): ShopifyFulfillmentService (per-package fulfillmentCreate + reconcile + GID map)"
```

---

### Task 5: `PackageShipmentSyncer`（編排三步）

**Files:** `app/services/package_shipment_syncer.rb`（新增）；`spec/services/package_shipment_syncer_spec.rb`

**Interfaces:**
- Consumes: `Raydo#mark_shipped`、`TrackingService#register`、`ShopifyFulfillmentService`。
- Produces: `PackageShipmentSyncer.new(package).call`。副作用：更新 `carrier_marked_at`/`tracking_registered_at`/`shopify_fulfillment_id`/`ship_sync_status`/`ship_sync_message`。分步冪等（有戳記/id 跳過）。Shopify 步驟在 `package.order.with_lock` 內（per-order 序列化）。

- [ ] **Step 1: Write the failing tests**

```ruby
require "rails_helper"
RSpec.describe PackageShipmentSyncer do
  # 共用前置 + shipped_ready_package，包裹先 update!(aasm_state: "shipped", ship_sync_status: "pending")
  def sync_pkg
    p = shipped_ready_package; p.update!(aasm_state: "shipped", ship_sync_status: "pending"); p
  end
  def stub_raydo_ok; stub_request(:get, "http://raydo.test:8082/postOrderApi.htm").with(query: hash_including({})).to_return(body: { ack: "true" }.to_json); end
  def stub_17track_ok; stub_request(:post, "https://api.17track.net/track/v2.4/register").to_return(body: { data: { accepted: [ { number: "TN900" } ], rejected: [] } }.to_json); end
  def stub_shopify_ok
    gql = "https://s.myshopify.com/admin/api/2024-10/graphql.json"
    stub_request(:post, gql).to_return do |req|
      body = JSON.parse(req.body)
      if body["query"].include?("fulfillments(") then { body: { data: { order: { fulfillments: [] } } }.to_json }
      elsif body["query"].include?("fulfillmentOrders") then { body: { data: { order: { fulfillmentOrders: { edges: [ { node: { id: "gid://shopify/FulfillmentOrder/1", status: "OPEN", lineItems: { edges: [ { node: { id: "gid://shopify/FulfillmentOrderLineItem/9", remainingQuantity: 2, lineItem: { id: "gid://shopify/LineItem/6900" } } } ] } } } ] } } } }.to_json }
      else { body: { data: { fulfillmentCreate: { fulfillment: { id: "gid://shopify/Fulfillment/77" }, userErrors: [] } } }.to_json } end
    end
  end

  before { store.company.update!(tracking_enabled: true, tracking_api_key: "k", tracking_mode: "track") }

  it "runs all 3 steps and marks succeeded" do
    stub_raydo_ok; stub_17track_ok; stub_shopify_ok
    p = sync_pkg
    described_class.new(p).call
    p.reload
    expect(p.ship_sync_status).to eq("succeeded")
    expect([ p.carrier_marked_at, p.tracking_registered_at ]).to all(be_present)
    expect(p.shopify_fulfillment_id).to eq("gid://shopify/Fulfillment/77")
  end

  it "is idempotent: skips a step whose completion marker is already set" do
    stub_17track_ok; stub_shopify_ok
    p = sync_pkg; p.update!(carrier_marked_at: 1.hour.ago) # 华磊 already done
    described_class.new(p).call
    expect(WebMock).not_to have_requested(:get, "http://raydo.test:8082/postOrderApi.htm")
    expect(p.reload.ship_sync_status).to eq("succeeded")
  end

  it "marks failed with a safe message when a step errors" do
    stub_raydo_ok
    stub_request(:post, "https://api.17track.net/track/v2.4/register").to_return(status: 500, body: "e")
    p = sync_pkg
    described_class.new(p).call
    p.reload
    expect(p.ship_sync_status).to eq("failed")
    expect(p.ship_sync_message).to be_present
  end

  it "treats 17track as success when it does not raise (already-registered dedupe)" do
    stub_raydo_ok; stub_shopify_ok
    stub_request(:post, "https://api.17track.net/track/v2.4/register").to_return(body: { data: { accepted: [], rejected: [ { number: "TN900", error: { code: -18019902 } } ] } }.to_json)
    p = sync_pkg
    described_class.new(p).call
    expect(p.reload.tracking_registered_at).to be_present
  end

  it "skips 17track (not a failure) when company tracking is not configured" do
    store.company.update!(tracking_enabled: false, tracking_api_key: nil)
    stub_raydo_ok; stub_shopify_ok
    p = sync_pkg
    described_class.new(p).call
    p.reload
    expect(p.tracking_registered_at).to be_nil
    expect(p.ship_sync_status).to eq("succeeded")
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/package_shipment_syncer_spec.rb`
Expected: FAIL — uninitialized constant.

- [ ] **Step 3: Implement**

`app/services/package_shipment_syncer.rb`：
```ruby
# Orchestrates the 3 shipment side-effects for one shipped package, each step
# idempotent (skips when its completion marker is set). Carrier + 17Track are
# safe to repeat; Shopify create is serialized per order and reconciled inside
# ShopifyFulfillmentService. Any step failure → ship_sync_status "failed" with a
# safe message; the package stays shipped. Enqueued only when the store's
# shipping_sync_enabled is on (see PackageShipSyncJob / controller).
class PackageShipmentSyncer
  def initialize(package)
    @package = package
    @company = package.shopify_store.company
  end

  def call
    mark_carrier
    register_tracking
    push_shopify
    @package.update!(ship_sync_status: "succeeded", ship_sync_message: nil)
  rescue => e
    @package.update!(ship_sync_status: "failed", ship_sync_message: safe_message(e))
    false
  end

  private

  def mark_carrier
    return if @package.carrier_marked_at.present?

    account = @package.logistics_channel&.logistics_account
    raise "logistics not configured" if account.nil?

    FulfillmentService.for(account).mark_shipped(@package.package_code)
    @package.update!(carrier_marked_at: Time.current)
  end

  def register_tracking
    return if @package.tracking_registered_at.present?
    # 17Track needs company config; missing → skip (not a failure).
    return unless @company.tracking_enabled? && @company.tracking_api_key.present?

    # register raises only on a real API/transport error; an already-registered
    # number returns 200 (rejected dedupe) and does NOT raise → treat as success.
    TrackingService.new(api_key: @company.tracking_api_key).register([ @package.tracking_number ])
    @package.update!(tracking_registered_at: Time.current)
  end

  def push_shopify
    return if @package.shopify_fulfillment_id.present?

    # Serialize per order so sibling packages of a split order don't race the
    # same fulfillment orders / remainingQuantity.
    @package.order.with_lock do
      @package.reload
      return if @package.shopify_fulfillment_id.present?

      id = ShopifyFulfillmentService.new(@package).call
      @package.update!(shopify_fulfillment_id: id)
    end
  end

  def safe_message(error)
    error.message.to_s.truncate(1000)
  end
end
```
> `mark_shipped`/`ShopifyFulfillmentService`/`TrackingService` 的錯誤訊息本身已是安全（class-only 或我方訊息）；`safe_message` 只截斷長度。

- [ ] **Step 4: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/package_shipment_syncer_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add app/services/package_shipment_syncer.rb spec/services/package_shipment_syncer_spec.rb
git commit -m "feat(packing): PackageShipmentSyncer orchestrates carrier/17track/shopify with idempotency"
```

---

### Task 6: `PackageShipSyncJob`

**Files:** `app/jobs/package_ship_sync_job.rb`（新增）；`spec/jobs/package_ship_sync_job_spec.rb`

**Interfaces:** Produces: `PackageShipSyncJob.perform_later(package_id)`。

- [ ] **Step 1: Write the failing tests**
```ruby
require "rails_helper"
RSpec.describe PackageShipSyncJob do
  # 共用前置 + shipped_ready_package
  it "syncs a shipped package" do
    store.company.update!(tracking_enabled: false, tracking_api_key: nil)
    p = shipped_ready_package; p.update!(aasm_state: "shipped", ship_sync_status: "pending", carrier_marked_at: 1.hour.ago, shopify_fulfillment_id: "gid://shopify/Fulfillment/1")
    described_class.perform_now(p.id)
    expect(p.reload.ship_sync_status).to eq("succeeded")
  end
  it "no-ops for a non-shipped package" do
    p = shipped_ready_package # pending_label
    described_class.perform_now(p.id)
    expect(p.reload.ship_sync_status).to eq("none")
  end
  it "no-ops for a missing id" do
    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/jobs/package_ship_sync_job_spec.rb`
Expected: FAIL — uninitialized constant.

- [ ] **Step 3: Implement**
```ruby
class PackageShipSyncJob < ApplicationJob
  queue_as :default

  def perform(package_id)
    package = Package.find_by(id: package_id)
    return unless package&.shipped?

    PackageShipmentSyncer.new(package).call
  rescue => e
    Rails.logger.error("[ShipSync] Package##{package_id}: #{e.class}: #{e.message}")
  end
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/jobs/package_ship_sync_job_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add app/jobs/package_ship_sync_job.rb spec/jobs/package_ship_sync_job_spec.rb
git commit -m "feat(packing): PackageShipSyncJob"
```

---

### Task 7: Controller `ship`/`ship_bulk`/`sync_shipment` + store 開關 + routes

**Files:** `config/routes.rb`；`app/controllers/packages_controller.rb`；`app/controllers/shopify_stores_controller.rb`；`spec/requests/packages_spec.rb`；`spec/requests/shopify_stores_spec.rb`

**Interfaces:** Produces: `POST /packages/:id/ship`、`POST /packages/ship_bulk`、`POST /packages/:id/sync_shipment`；`ShopifyStore` 開關 owner-gated update。

- [ ] **Step 1: Write the failing request tests**

在 `spec/requests/packages_spec.rb` 新增（自建 `sign_in_as_member_with`；共用前置 + `label_ready` package pending_label + channel/account/store）：
```ruby
describe "shipping" do
  def sign_in_as_member_with(permission)
    member = create(:user); create(:membership, user: member, company: company, role: :member, permissions: [ permission ]); sign_in member
  end
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089", customer_id: "6581", customer_userid: "6901") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }
  def pl_pkg(number: 900, state: "pending_label", tn: "TN900")
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#S#{number}")
    create(:package, shopify_store: store, order: order, number: number, aasm_state: state, logistics_channel: channel, raydo_order_id: "R#{number}", tracking_number: tn)
  end

  describe "POST /packages/:id/ship" do
    it "ships + enqueues sync when the store toggle is ON" do
      store.update!(shipping_sync_enabled: true)
      pkg = pl_pkg
      expect { post ship_package_path(id: pkg.id), headers: { "Accept" => "text/vnd.turbo-stream.html" } }
        .to have_enqueued_job(PackageShipSyncJob).with(pkg.id)
      pkg.reload
      expect(pkg).to have_state(:shipped)
      expect(pkg.ship_sync_status).to eq("pending")
    end
    it "ships WITHOUT sync when the toggle is OFF (test mode)" do
      store.update!(shipping_sync_enabled: false)
      pkg = pl_pkg
      expect { post ship_package_path(id: pkg.id) }.not_to have_enqueued_job(PackageShipSyncJob)
      pkg.reload
      expect(pkg).to have_state(:shipped)
      expect(pkg.ship_sync_status).to eq("none")
    end
    it "rejects (422/redirect) shipping without a tracking number" do
      pkg = pl_pkg(tn: nil)
      post ship_package_path(id: pkg.id)
      expect(pkg.reload).to have_state(:pending_label)
    end
    it "rejects a non-pending_label package" do
      pkg = pl_pkg(state: "shipped")
      post ship_package_path(id: pkg.id)
      expect(response).to have_http_status(:found)
    end
    it "forbids a member without package_shipping" do
      pkg = pl_pkg; sign_in_as_member_with("package_process")
      post ship_package_path(id: pkg.id)
      expect(pkg.reload).to have_state(:pending_label)
    end
    it "404s for another company's package" do
      pkg = pl_pkg; sign_in create(:user)
      post ship_package_path(id: pkg.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /packages/:id/sync_shipment" do
    it "re-enqueues for a failed shipped package when toggle ON" do
      store.update!(shipping_sync_enabled: true)
      pkg = pl_pkg(state: "shipped"); pkg.update!(ship_sync_status: "failed")
      expect { post sync_shipment_package_path(id: pkg.id) }.to have_enqueued_job(PackageShipSyncJob).with(pkg.id)
      expect(pkg.reload.ship_sync_status).to eq("pending")
    end
    it "rejects when the store toggle is OFF" do
      pkg = pl_pkg(state: "shipped"); pkg.update!(ship_sync_status: "none")
      post sync_shipment_package_path(id: pkg.id)
      expect(response).to have_http_status(:found)
    end
  end

  describe "POST /packages/ship_bulk" do
    it "ships selected pending_label packages" do
      store.update!(shipping_sync_enabled: false)
      a = pl_pkg(number: 901, tn: "T1"); b = pl_pkg(number: 902, tn: "T2")
      post ship_bulk_packages_path, params: { package_ids: [ a.id, b.id ] }
      expect(a.reload).to have_state(:shipped)
      expect(b.reload).to have_state(:shipped)
    end
  end
end
```

`spec/requests/shopify_stores_spec.rb`（沿用該檔 owner sign-in + store 建置）：
```ruby
it "updates shipping_sync_enabled (owner only)" do
  patch shopify_store_path(id: store.id), params: { shopify_store: { shipping_sync_enabled: true } }
  expect(store.reload.shipping_sync_enabled).to be(true)
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/packages_spec.rb -e shipping`
Expected: FAIL — `undefined method 'ship_package_path'`.

- [ ] **Step 3: Routes**

`config/routes.rb` packages block：member 加 `post :ship`、`post :sync_shipment`；collection 加 `post :ship_bulk`。

- [ ] **Step 4: Controller — PackagesController**

`set_package` `only:` 加 `:ship, :sync_shipment`。在 label/labels 之後加：
```ruby
  def ship
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_shipping?

    result = ship_package(@package)
    if result == :ok
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace("package-modal", partial: "packages/modal", locals: { package: @package.reload }) }
        format.html { redirect_to package_path(id: @package.id), notice: t("packages.ship.done") }
      end
    else
      redirect_to package_path(id: @package.id), alert: t("packages.ship.errors.#{result}", default: t("packages.ship.errors.failed"))
    end
  end

  def ship_bulk
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_shipping?

    ids = Array(params[:package_ids]).map(&:to_s)
    shipped = 0
    scoped_packages.where(id: ids, aasm_state: "pending_label").find_each do |package|
      shipped += 1 if ship_package(package) == :ok
    rescue => e
      Rails.logger.warn("[ShipBulk] Package##{package.id}: #{e.class}: #{e.message}")
    end
    redirect_to packages_path(state: "pending_label"), notice: t("packages.ship.bulk_result", shipped: shipped)
  end

  def sync_shipment
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_shipping?
    unless @package.shipped? && %w[failed none].include?(@package.ship_sync_status)
      return redirect_to(package_path(id: @package.id), alert: t("packages.ship.errors.sync_invalid"))
    end
    unless @package.shopify_store.shipping_sync_enabled?
      return redirect_to(package_path(id: @package.id), alert: t("packages.ship.errors.sync_disabled"))
    end

    @package.update!(ship_sync_status: "pending", ship_sync_message: nil)
    PackageShipSyncJob.perform_later(@package.id)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace("package-modal", partial: "packages/modal", locals: { package: @package.reload }) }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.ship.sync_enqueued") }
    end
  end
```
private helper：
```ruby
  # Atomically transition to shipped + set status + decide enqueue (Codex: row
  # lock to avoid double-click races). Returns :ok, :not_pending, :no_tracking.
  def ship_package(package)
    enqueue = false
    outcome = package.with_lock do
      next :not_pending unless package.pending_label?
      next :no_tracking if package.tracking_number.blank?

      package.ship!
      attrs = { shipped_at: Time.current }
      if package.shopify_store.shipping_sync_enabled?
        attrs.merge!(ship_sync_status: "pending", ship_sync_message: nil)
        enqueue = true
      end
      package.update!(attrs)
      :ok
    end
    PackageShipSyncJob.perform_later(package.id) if enqueue && outcome == :ok
    outcome
  end
```

- [ ] **Step 5: Controller — ShopifyStoresController 開關分支**

在 `update` 的分支鏈加入（比照既有 owner-gated 分支）：
```ruby
    if params[:shopify_store].is_a?(ActionController::Parameters) && params[:shopify_store].key?(:shipping_sync_enabled)
      return redirect_to(shopify_store_path(@shopify_store), alert: t("companies.no_permission")) unless current_membership&.owner?

      if @shopify_store.update(shopify_store_shipping_sync_params)
        redirect_to shopify_store_path(@shopify_store), notice: t("shopify_stores.shipping_sync_updated")
      else
        redirect_to shopify_store_path(@shopify_store), alert: @shopify_store.errors.full_messages.join(", ")
      end
      return
    end
```
private permit：
```ruby
  def shopify_store_shipping_sync_params
    params.require(:shopify_store).permit(:shipping_sync_enabled)
  end
```

- [ ] **Step 6: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/packages_spec.rb -e shipping spec/requests/shopify_stores_spec.rb`
Expected: PASS. （i18n `packages.ship.*` / `shopify_stores.shipping_sync_updated` 於 Task 8 補；`t(..., default:)` 有 default、測試只斷言 status 不炸。）

- [ ] **Step 7: Commit**
```bash
git add config/routes.rb app/controllers/packages_controller.rb app/controllers/shopify_stores_controller.rb spec/requests
git commit -m "feat(packing): ship/ship_bulk/sync_shipment actions + store shipping_sync toggle"
```

---

### Task 8: UI — 發貨鈕、同步狀態/立即同步、批量、店鋪開關 + reauth 提示、i18n

**Files:** `app/views/packages/_actions.html.erb`；`app/views/packages/index.html.erb`；店鋪設定 view（`app/views/shopify_stores/show.html.erb` 或設定 partial）；`config/locales/{en,zh-TW,zh-CN}.yml`

**Interfaces:** Consumes: `ship_package_path`/`ship_bulk_packages_path`/`sync_shipment_package_path`；`Package#pending_label?`/`#shipped?`/`#ship_sync_status`/`#ship_sync_message`；`ShopifyStore#shipping_sync_enabled`/`#fulfillment_write_scope?`。

- [ ] **Step 1: i18n（三語系，zh-TW 繁體 / zh-CN 简体 / en 英；結構一致）**

`packages:` 下加 `ship:`（button/bulk_button/done/bulk_result/sync_now/sync_enqueued + errors.{failed,not_pending,no_tracking,sync_invalid,sync_disabled}）與 `ship_sync:`（pending/succeeded/failed 標籤）。`shopify_stores:` 下加 `shipping_sync`、`shipping_sync_updated`、`shipping_sync_hint`、`reauth_needed`。（示範 zh-TW：ship.button「發貨」、sync_now「立即同步」、ship_sync.pending「同步中」/succeeded「已同步」/failed「同步失敗」、reauth_needed「需重新授權店鋪才能回寫 Shopify」。）

- [ ] **Step 2: `_actions` 發貨 + 立即同步 按鈕**

在 `_actions.html.erb` 末尾加：
```erb
  <% if package.pending_label? && current_membership&.package_shipping? %>
    <%= button_to t("packages.ship.button"), ship_package_path(id: package.id),
        method: :post, form: { data: { turbo_frame: "package-modal" } },
        class: "px-4 py-2 bg-emerald-600 text-white text-sm rounded hover:bg-emerald-700" %>
  <% end %>
  <% if package.shipped? && current_membership&.package_shipping? && package.shopify_store.shipping_sync_enabled? &&
        %w[failed none].include?(package.ship_sync_status) %>
    <%= button_to t("packages.ship.sync_now"), sync_shipment_package_path(id: package.id),
        method: :post, form: { data: { turbo_frame: "package-modal" } },
        class: "px-4 py-2 bg-amber-600 text-white text-sm rounded hover:bg-amber-700" %>
  <% end %>
```
並在 modal 適當處（比照 2C 的 application_status 區塊）加一個 shipped 同步狀態顯示 partial `_ship_status.html.erb`（`dom_id(package, :ship_status)`，顯示 `ship_sync_status` 標籤 + `ship_sync_message`）。在 `_modal.html.erb` render 它。

- [ ] **Step 3: index 批量發貨（pending_label）**

`index.html.erb` 的 bulk 一般化再擴充：`pending_label` 狀態的批量表單 URL 依動作而定——本階段 pending_label 已有「批量打印面单」(2D)。**加一個第二批量動作「批量發貨」**：最簡做法是 pending_label 清單提供兩顆 submit（同一個多選集合，兩個 formaction）——一顆 `formaction=labels_packages_path`（印面單，target=_blank）、一顆 `formaction=ship_bulk_packages_path`（發貨）。即在 bulk bar 放兩顆 `submit_tag ... , formaction: ...`。sanity：pending_label bulk bar 顯示「批量打印面单」+「批量發貨」兩鈕。

- [ ] **Step 4: 店鋪設定頁 開關 + reauth 提示**

在店鋪設定 view 加一個 `shipping_sync_enabled` 開關表單（`form_with model: @shopify_store, method: :patch`，欄位 `f.check_box :shipping_sync_enabled` + submit；提交只帶 `shipping_sync_enabled` → 命中新分支）。並在 `!@shopify_store.fulfillment_write_scope?` 時顯示 `t("shopify_stores.reauth_needed")` 提示（連到既有 OAuth 重新連結流程的入口）。

- [ ] **Step 5: Sanity checks**

Run:
```
PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rails runner "%w[en zh-TW zh-CN].each { |l| I18n.locale=l; %w[packages.ship.button packages.ship.sync_now packages.ship.bulk_button packages.ship_sync.pending shopify_stores.shipping_sync shopify_stores.reauth_needed].each { |k| raise \"missing #{k} in #{l}\" unless I18n.exists?(k) } }; puts 'i18n ok'"
PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/packages_spec.rb spec/requests/shopify_stores_spec.rb
PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rubocop
```
Expected: i18n ok；request specs 綠；RuboCop 0。

- [ ] **Step 6: Commit**
```bash
git add app/views config/locales
git commit -m "feat(packing): ship button, sync status/sync-now, bulk ship, store toggle + reauth hint + i18n"
```

---

### Task 9: System specs

**Files:** `spec/system/packages_spec.rb`；（可選）`spec/system/shopify_stores_spec.rb`

- [ ] **Step 1: System tests**

在 `spec/system/packages_spec.rb` 新增（`sign_in_as(user)`；WebMock stub 外部；toggle OFF 情境最單純——只驗狀態轉換 + 按鈕）：
```ruby
describe "發貨" do
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089", customer_id: "1", customer_userid: "2") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }
  def pl_pkg(number: 900)
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#S#{number}")
    create(:package, shopify_store: store, order: order, number: number, aasm_state: "pending_label", logistics_channel: channel, raydo_order_id: "R#{number}", tracking_number: "TN#{number}")
  end

  it "ships a package (test mode) and moves it out of pending_label" do
    store.update!(shipping_sync_enabled: false)
    pkg = pl_pkg
    visit packages_path(state: "pending_label")
    click_link pkg.package_code
    expect(page).to have_button(I18n.t("packages.ship.button"))
    click_button I18n.t("packages.ship.button")
    expect(pkg.reload).to have_state(:shipped)
  end

  it "shows the bulk ship button when a pending_label row is checked" do
    pl_pkg
    visit packages_path(state: "pending_label")
    first("input[name='package_ids[]']").check
    expect(page).to have_button(I18n.t("packages.ship.bulk_button"))
  end
end
```
> chromedriver：若超前 Chrome，`/tmp/chromedriver-linux64` 前置 PATH（[[local-system-test-chromedriver]]）。

- [ ] **Step 2: Run**

Run: `PATH=/tmp/chromedriver-linux64:/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/system/packages_spec.rb -e 發貨`
Expected: PASS.

- [ ] **Step 3: Commit**
```bash
git add spec/system/packages_spec.rb
git commit -m "test(packing): system specs for ship + bulk ship"
```

---

### Task 10: 全套驗證 + PR

- [ ] **Step 1: Full suite**

Run: `PATH=/tmp/chromedriver-linux64:/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec`
Expected: 全綠、coverage ≥ 95%。既知 flaky（[[flaky-system-tests]]）重跑確認；2E 真實失敗須停下修。

- [ ] **Step 2: Lint + security**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rubocop && bin/brakeman --no-pager`
Expected: RuboCop 0；Brakeman 無新警告（留意 `params[:package_ids]` 僅用於 where；GraphQL/HTTParty 呼叫）。

- [ ] **Step 3: Push + PR**
```bash
git push -u origin feature/order-packing-phase2e-ship
```
`gh pr create --base staging`（標題 `feat(packing): Phase 2E 已交运(shipped) + 同步开关`）。**PR 內文務必標明：部署後兩個店鋪需重新授權(reauth)才有 `write_merchant_managed_fulfillment_orders` scope、Shopify 回寫才生效；`shipping_sync_enabled` 預設 false（測試模式）；華磊 postOrderApi 回應保守判定待實測。** 結尾加 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。

---

## Self-Review（對照 spec）

- **Spec 覆蓋**：migration+索引+scope 偵測→T1；OAuth scope→T2；Raydo#mark_shipped→T3；Shopify 逐包裹回寫(GID/序列化在 syncer/對帳)→T4；PackageShipmentSyncer(三步/冪等/per-order 鎖/17track already=success/缺 key 跳過)→T5；job→T6；controller ship/bulk/sync_shipment(with_lock/toggle/none 補救)+store 開關→T7；UI+i18n+reauth 提示→T8；system→T9；驗證/PR→T10。全部有對應任務。
- **Placeholder 掃描**：無 TBD/TODO；每步附程式碼與指令。華磊回應保守判定以常數/註解標示，非 placeholder。
- **型別一致**：`Raydo#mark_shipped(code)→true`、`ShopifyFulfillmentService.new(pkg).call→String(gid)`（`Error`）、`PackageShipmentSyncer.new(pkg).call`、`PackageShipSyncJob.perform_later(id)`、`ShopifyStore#fulfillment_write_scope?`、route helpers `ship_package_path`/`ship_bulk_packages_path`/`sync_shipment_package_path`、`ship_package→:ok/:not_pending/:no_tracking`、`ship_sync_status` 值域 一致。
- **執行時對齊**（已標註）：per-order 序列化在 `PackageShipmentSyncer#push_shopify`（非 T4 service 內），T4 service 專注單次建立+對帳；`have_enqueued_job` 用 test adapter（既有 `ActiveJob::TestHelper, type: :request`）；Shopify GraphQL 測試沿用 `shopify_analytics_service_spec` 的 Context/session 前置與 graphql.json WebMock；oauth/shopify_stores request spec 對齊各檔既有慣例；i18n `packages.ship.*` 在 T8、T7 用 `t(default:)`；index pending_label bulk 用「兩個 formaction submit」共用多選集合。
