# 訂單打包 Phase 2C — 申請運單號 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓操作者對齊全的 `pending_process` 包裹（單筆或批量）向華磊(Raydo)貨代申請運單號，成功後進 `pending_label`；延遲出號用週期輪詢補齊。

**Architecture:** `FulfillmentService::Raydo` 新增 `create_order`/`get_tracking_number`；`PackageTrackingApplier` 編排單一包裹的建單/取號與狀態轉換；`ApplyTrackingJob`（單筆與批量 fan-out 共用）+ `PollTrackingNumbersJob`（recurring，每 5 分鐘，24h 放棄）。Controller 提供 apply/retry/bulk，gate 於 `package_process?`。

**Tech Stack:** Rails 8.1、AASM、Solid Queue（recurring.yml）、HTTParty、Hotwire(Turbo+Stimulus)、Tailwind、PostgreSQL(UUID)、RSpec + FactoryBot + WebMock。

## Global Constraints

- 所有 table id 用 UUID。
- 測試：RSpec + FactoryBot，**不 mock DB、打真 DB、95%+ line coverage**；外部 HTTP 一律用 **WebMock `stub_request`**（`WebMock.disable_net_connect!`）。每功能 model/service + request + system。
- 絕不 commit 到 `staging`/`main`；在 `feature/order-packing-phase2c` 上做。推送用 `git push -u origin feature/order-packing-phase2c`（**upstream 指向 origin/staging，勿裸 `git push`**）。
- 齊全 gate 就在申請運單號按鈕（`Package#ready_for_tracking?`）；審核放行無條件（沿用 2B-2 決策）。
- 權限 gate：apply/retry/bulk 全部 `current_membership&.package_process?`（owner 通過）。每個寫入 action 先 `set_package`（`scoped_packages.find` → 跨公司 404）再過權限。失敗一律 422/redirect，**絕不 500**。
- Ruby toolchain：跑 rspec/rails 前 PATH 前置 `/home/simon/.rubies/ruby-3.4.7/bin`。單檔 rspec 因 SimpleCov 可能 exit 2，屬預期（看「N examples, 0 failures」）。
- 外部 API 錯誤：華磊憑證在 query/body，錯誤訊息**不可**外洩（沿用 raydo.rb 既有做法，只露 exception class）。
- 溝通用繁體中文；程式碼/路徑/commit 用英文。
- 華磊 API 細節見 `docs/superpowers/references/raydo-huali-api.md`。

---

## File Structure

- **Migration** `db/migrate/*_add_tracking_application_fields_to_packages.rb`（新增）— packages 加 5 欄。
- **`app/models/package.rb`**（改）— `back_to_process` after 清欄位 + 狀態小工具。
- **`app/services/fulfillment_service/raydo.rb`**（改）— `create_order`、`get_tracking_number`、`post` 輔助、`CreateResult`/`TrackResult`。
- **`app/services/package_tracking_applier.rb`**（新增）— 單包裹編排。
- **`app/jobs/apply_tracking_job.rb`**、**`app/jobs/poll_tracking_numbers_job.rb`**（新增）。
- **`config/recurring.yml`**（改）— 註冊 poll job（prod+dev）。
- **`app/controllers/packages_controller.rb`**（改）— apply_tracking/retry_tracking/apply_tracking_bulk。
- **`config/routes.rb`**（改）— member apply_tracking/retry_tracking；collection apply_tracking_bulk。
- **Views**（新增/改）：`_actions.html.erb`（apply/retry 鈕）、`_application_status.html.erb`（applying_tracking 狀態）、`apply_tracking.turbo_stream.erb`、`index.html.erb`（pending_process 批量列 + 批次鈕）、`_package_row.html.erb`（checkbox）、`apply_tracking_bulk` flash。
- **`app/javascript/controllers/package_bulk_controller.js`**（新增）— 輕量批量勾選（顯示批次鈕 + 計數）。
- **i18n** `config/locales/{en,zh-TW,zh-CN}.yml`（改）。
- **Specs**：`spec/models/package_spec.rb`、`spec/services/fulfillment_service/raydo_spec.rb`、`spec/services/package_tracking_applier_spec.rb`（新）、`spec/jobs/apply_tracking_job_spec.rb`（新）、`spec/jobs/poll_tracking_numbers_job_spec.rb`（新）、`spec/requests/packages_spec.rb`、`spec/system/packages_spec.rb`。

**共用測試前置**（各 spec 沿用現有慣例）：

```ruby
let(:user)     { create(:user) }
let(:company)  { user.companies.first }
let(:store)    { create(:shopify_store, user: user, company: company, package_prefix: "XMBDE", package_number_start: 2013094) }
let(:customer) { create(:customer, shopify_store: store) }
let(:account)  { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", customer_id: "6581", customer_userid: "6901") }
let(:channel)  { create(:logistics_channel, logistics_account: account, product_id: "P1") }

def ready_process_package
  order = create(:order, customer: customer, shopify_store: store)
  pkg = create(:package, shopify_store: store, order: order, aasm_state: "pending_process",
               logistics_channel: channel, address_overridden: true,
               shipping_address_snapshot: { "name" => "Amy", "address1" => "1 Rue", "city" => "Paris",
                                            "province" => "IDF", "zip" => "75001", "country_code" => "FR", "phone" => "0102030405" })
  oli = create(:order_line_item, order: order)
  create(:package_item, package: pkg, order_line_item: oli, sku: "A", title: "Art",
         quantity: 2, refunded_quantity: 0, customs_name_zh: "画", customs_name_en: "Painting",
         declared_value_usd: 20, customs_weight_grams: 500, hs_code: "9701", customs_overridden: true)
  pkg
end
```

---

### Task 1: Migration + Package 欄位清理與狀態工具

**Files:**
- Create: `db/migrate/YYYYMMDDHHMMSS_add_tracking_application_fields_to_packages.rb`
- Modify: `db/schema.rb`（由 migrate 產生）
- Modify: `app/models/package.rb`
- Test: `spec/models/package_spec.rb`

**Interfaces:**
- Produces:
  - packages 欄位 `raydo_order_id:string`, `tracking_number:string`, `carrier:string`, `application_message:text`, `applied_at:datetime`。
  - `Package#back_to_process!` 之後清空這 5 欄 + `application_status="none"`。

- [ ] **Step 1: Write the failing test**

`spec/models/package_spec.rb` 新增（用上方共用前置）：

```ruby
describe "back_to_process clears the tracking-application fields" do
  it "resets application fields when pulled back to pending_process" do
    pkg = ready_process_package
    pkg.update!(aasm_state: "applying_tracking", application_status: "succeeded",
                raydo_order_id: "R123", tracking_number: "TN999", carrier: "DHL",
                application_message: "x", applied_at: Time.current)
    pkg.back_to_process!
    pkg.reload
    expect(pkg).to have_state(:pending_process)
    expect(pkg.application_status).to eq("none")
    expect([ pkg.raydo_order_id, pkg.tracking_number, pkg.carrier, pkg.application_message, pkg.applied_at ]).to all(be_nil)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/models/package_spec.rb -e "back_to_process clears"`
Expected: FAIL — `NoMethodError: undefined method 'raydo_order_id='`（欄位未建）。

- [ ] **Step 3: Write the migration**

`bin/rails g migration AddTrackingApplicationFieldsToPackages` 後貼入：

```ruby
class AddTrackingApplicationFieldsToPackages < ActiveRecord::Migration[8.1]
  def change
    add_column :packages, :raydo_order_id, :string
    add_column :packages, :tracking_number, :string
    add_column :packages, :carrier, :string
    add_column :packages, :application_message, :text
    add_column :packages, :applied_at, :datetime
  end
end
```

- [ ] **Step 4: Add the back_to_process clear in the model**

在 `app/models/package.rb` 的 `back_to_process` 事件加 `after`（比照 unhold 的 update_columns，因 after 跑在 save 之後需直接持久化）：

```ruby
    event :back_to_process do
      # Pulling a package back to processing discards its tracking application
      # (Y decision): a re-apply will create a NEW Raydo order. after runs
      # post-save, so persist the clear directly rather than mutating memory.
      after do
        update_columns(application_status: "none", raydo_order_id: nil, tracking_number: nil,
                       carrier: nil, application_message: nil, applied_at: nil)
      end
      transitions from: [ :applying_tracking, :pending_label ], to: :pending_process
    end
```

- [ ] **Step 5: Migrate and run the test**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rails db:migrate && bin/rails db:test:prepare && bundle exec rspec spec/models/package_spec.rb -e "back_to_process clears"`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/package.rb spec/models/package_spec.rb
git commit -m "feat(packing): add tracking-application fields to packages; clear on back_to_process"
```

---

### Task 2: `FulfillmentService::Raydo#create_order` + `#get_tracking_number`

**Files:**
- Modify: `app/services/fulfillment_service/raydo.rb`
- Test: `spec/services/fulfillment_service/raydo_spec.rb`

**Interfaces:**
- Consumes: `Package`（含 `shipping_address_snapshot`、`logistics_channel`、`shippable_items`、`package_code`）；`LogisticsAccount`（`customer_id`/`customer_userid`/`url1_base`）。
- Produces:
  - `FulfillmentService::Raydo::CreateResult`（`success?`, `order_id`, `tracking_number`, `deferred?`, `message`）。
  - `FulfillmentService::Raydo::TrackResult`（`ready?`, `tracking_number`, `carrier`, `message`）。
  - `#create_order(package) → CreateResult`；`#get_tracking_number(order_id) → TrackResult`。

- [ ] **Step 1: Write the failing tests**

在 `spec/services/fulfillment_service/raydo_spec.rb` 新增（沿用檔案既有 `let(:account)`；下面自帶 package 建置）：

```ruby
describe "#create_order" do
  let(:store)   { create(:shopify_store, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }
  let(:account) { create(:logistics_account, url1_base: "http://raydo.test:8082", customer_id: "6581", customer_userid: "6901") }
  let(:package) do
    order = create(:order, shopify_store: store)
    pkg = create(:package, shopify_store: store, order: order, number: 2013094, aasm_state: "pending_process",
                 logistics_channel: channel,
                 shipping_address_snapshot: { "name" => "Amy", "address1" => "1 Rue", "city" => "Paris",
                                              "province" => "IDF", "zip" => "75001", "country_code" => "FR", "phone" => "0102030405" })
    oli = create(:order_line_item, order: order)
    create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 2, refunded_quantity: 0,
           customs_name_zh: "画", customs_name_en: "Painting", declared_value_usd: 20, customs_weight_grams: 500,
           hs_code: "9701", import_hs_code: "9701.10")
    pkg
  end

  it "returns success with an immediate tracking number" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "true", order_id: "R123", tracking_number: "TN999", is_delay: "N", product_tracknoapitype: "" }.to_json,
                headers: { "Content-Type" => "application/json" })
    r = described_class.new(account).create_order(package)
    expect(r.success?).to be(true)
    expect(r.deferred?).to be(false)
    expect(r.order_id).to eq("R123")
    expect(r.tracking_number).to eq("TN999")
  end

  it "sends the mapped consignee, product_id, customer ids, reference code and invoice items" do
    stub = stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      with { |req|
        payload = JSON.parse(CGI.unescape(req.body.sub(/\Aparam=/, "")))
        payload["consignee_name"] == "Amy" && payload["country"] == "FR" &&
          payload["product_id"] == "P1" && payload["customer_id"] == "6581" &&
          payload["customer_userid"] == "6901" && payload["order_customerinvoicecode"] == package.package_code &&
          payload["orderInvoiceParam"].first["invoice_title"] == "Painting" &&
          payload["orderInvoiceParam"].first["sku"] == "画" &&
          payload["orderInvoiceParam"].first["invoice_pcs"] == 2
      }.to_return(body: { ack: "true", order_id: "R1", tracking_number: "T1" }.to_json)
    described_class.new(account).create_order(package)
    expect(stub).to have_been_requested
  end

  it "flags deferred when is_delay is Y" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "true", order_id: "R2", tracking_number: "", is_delay: "Y" }.to_json)
    r = described_class.new(account).create_order(package)
    expect(r.success?).to be(true)
    expect(r.deferred?).to be(true)
    expect(r.order_id).to eq("R2")
  end

  it "flags deferred when product_tracknoapitype is 3" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "true", order_id: "R3", tracking_number: "X", product_tracknoapitype: "3" }.to_json)
    expect(described_class.new(account).create_order(package).deferred?).to be(true)
  end

  it "returns failure with a urldecoded message on ack=false" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "false", message: "%E5%9C%B0%E5%9D%80%E9%94%99%E8%AF%AF" }.to_json) # 地址错误
    r = described_class.new(account).create_order(package)
    expect(r.success?).to be(false)
    expect(r.message).to eq("地址错误")
  end
end

describe "#get_tracking_number" do
  it "returns ready with the serve invoice code when status is 200" do
    stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").
      with(query: { order_id: "R123" }).
      to_return(body: { status: "200", msg: "获取成功", order_serveinvoicecode: "SF123", express_type: "SF" }.to_json)
    r = described_class.new(account).get_tracking_number("R123")
    expect(r.ready?).to be(true)
    expect(r.tracking_number).to eq("SF123")
    expect(r.carrier).to eq("SF")
  end

  it "is not ready when the serve invoice code is still empty" do
    stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").
      with(query: { order_id: "R123" }).
      to_return(body: { status: "200", order_serveinvoicecode: "" }.to_json)
    expect(described_class.new(account).get_tracking_number("R123").ready?).to be(false)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/fulfillment_service/raydo_spec.rb -e create_order -e get_tracking_number`
Expected: FAIL — `NoMethodError: undefined method 'create_order'`。

- [ ] **Step 3: Implement create_order / get_tracking_number**

在 `app/services/fulfillment_service/raydo.rb` 的 `class Raydo` 內、`product_list` 之後加入（單位換算常數 + Result structs + 方法 + post 輔助 + payload 建構）：

```ruby
    # Grams -> Raydo weight unit. Doc doesn't state the unit; we send kg
    # (grams / 1000). Confirm with the carrier and adjust this one constant if
    # they expect grams.
    WEIGHT_DIVISOR = 1000.0

    CreateResult = Struct.new(:success, :order_id, :tracking_number, :deferred, :message, keyword_init: true) do
      def success? = !!success
      def deferred? = !!deferred
    end

    TrackResult = Struct.new(:ready, :tracking_number, :carrier, :message, keyword_init: true) do
      def ready? = !!ready
    end

    # POST url1/createOrderApi.htm  body: param=<url-encoded JSON>
    def create_order(package)
      res = post("/createOrderApi.htm", param: order_payload(package).to_json)
      res = {} unless res.is_a?(Hash)
      success = res["ack"].to_s == "true"
      tracking = res["tracking_number"].to_s
      deferred = res["is_delay"].to_s == "Y" || res["product_tracknoapitype"].to_s == "3" || tracking.blank?
      CreateResult.new(
        success: success,
        order_id: res["order_id"].presence,
        tracking_number: tracking.presence,
        deferred: deferred,
        message: success ? nil : urldecode(res["message"])
      )
    end

    # GET url1/getOrderTrackingNumber.htm?order_id=  -> latest-leg tracking no.
    def get_tracking_number(order_id)
      res = get("/getOrderTrackingNumber.htm", order_id: order_id)
      res = {} unless res.is_a?(Hash)
      serve = res["order_serveinvoicecode"].to_s
      TrackResult.new(
        ready: res["status"].to_s == "200" && serve.present?,
        tracking_number: serve.presence,
        carrier: res["express_type"].presence,
        message: res["msg"].presence
      )
    end

    private

    # Customer ids for order creation: prefer the stored ones, else authenticate.
    def customer_ids
      cid = @account.customer_id.presence
      uid = @account.customer_userid.presence
      return [ cid, uid ] if cid && uid

      auth = authenticate
      [ auth["customer_id"], auth["customer_userid"] ]
    end

    def order_payload(package)
      snap = package.shipping_address_snapshot || {}
      cid, uid = customer_ids
      {
        consignee_name: snap["name"],
        consignee_companyname: snap["company"],
        consignee_address: [ snap["address1"], snap["address2"] ].reject(&:blank?).join(" "),
        consignee_telephone: snap["phone"],
        country: snap["country_code"],
        consignee_state: snap["province"],
        consignee_city: snap["city"],
        consignee_postcode: snap["zip"],
        product_id: package.logistics_channel&.product_id,
        order_customerinvoicecode: package.package_code,
        customer_id: cid,
        customer_userid: uid,
        order_piece: 1,
        weight: package_weight_kg(package),
        orderInvoiceParam: package.shippable_items.map { |it| invoice_param(it) }
      }.compact
    end

    def invoice_param(item)
      {
        invoice_title: item.customs_name_en,
        sku: item.customs_name_zh,
        invoice_amount: item.declared_value_usd,
        invoice_weight: to_kg(item.customs_weight_grams),
        invoice_pcs: item.quantity - item.refunded_quantity,
        hs_code: item.hs_code,
        import_hs_code: item.import_hs_code
      }.compact
    end

    def package_weight_kg(package)
      grams = package.shippable_items.sum { |it| it.customs_weight_grams.to_f * (it.quantity - it.refunded_quantity) }
      grams.positive? ? (grams / WEIGHT_DIVISOR).round(3) : nil
    end

    def to_kg(grams)
      grams.present? ? (grams.to_f / WEIGHT_DIVISOR).round(3) : nil
    end

    def urldecode(value)
      return nil if value.blank?

      CGI.unescape(value.to_s)
    rescue ArgumentError
      value.to_s
    end

    # POST form body (application/x-www-form-urlencoded); reuses the GBK/single-
    # quote-tolerant parser. Same credential-safe error handling as #get.
    def post(path, body = {})
      raise FulfillmentService::Error, "Raydo base URL is not configured" if @account.url1_base.blank?

      base = @account.url1_base.to_s.chomp("/")
      resp = HTTParty.post("#{base}#{path}", body: body, timeout: 30)
      raise FulfillmentService::Error, "Raydo HTTP #{resp.code}" unless resp.success?
      parse_response(resp)
    rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, IO::TimeoutError, Timeout::Error, SocketError, SystemCallError => e
      raise FulfillmentService::Error, "Raydo connection failed (#{e.class})"
    rescue URI::InvalidURIError, ArgumentError => e
      raise FulfillmentService::Error, "Raydo request failed (#{e.class})"
    end
```

> 注意：`create_order`/`get_tracking_number` 是 public，需放在既有 `private` 之前；上面把新的 `private` 段接在方法之後。實作時把新 public 方法置於 `product_list` 與原 `private` 之間，新 private helpers 併入既有 private 區塊（避免出現兩個 `private`；若合併困難，兩個 `private` 在 Ruby 也合法，但 RuboCop 可能有 Style 提示——以單一 private 區塊為佳）。

- [ ] **Step 4: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/fulfillment_service/raydo_spec.rb`
Expected: PASS（新測試 + 既有 auth/product_list 測試全綠）。

- [ ] **Step 5: Commit**

```bash
git add app/services/fulfillment_service/raydo.rb spec/services/fulfillment_service/raydo_spec.rb
git commit -m "feat(packing): Raydo create_order + get_tracking_number adapter methods"
```

---

### Task 3: `PackageTrackingApplier` service

**Files:**
- Create: `app/services/package_tracking_applier.rb`
- Test: `spec/services/package_tracking_applier_spec.rb`

**Interfaces:**
- Consumes: `FulfillmentService.for(account) → Raydo`；`Raydo#create_order`/`#get_tracking_number`；`Package#to_label!`。
- Produces: `PackageTrackingApplier.new(package).call`。副作用：更新 `application_status`/`raydo_order_id`/`tracking_number`/`carrier`/`application_message`/`applied_at`、成功時 `to_label!`。假設 package 已在 `applying_tracking`。

- [ ] **Step 1: Write the failing tests**

`spec/services/package_tracking_applier_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe PackageTrackingApplier do
  let(:company) { create(:company) }
  let(:store)   { create(:shopify_store, company: company, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", customer_id: "6581", customer_userid: "6901") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }
  let(:package) do
    order = create(:order, shopify_store: store)
    pkg = create(:package, shopify_store: store, order: order, number: 2013094, aasm_state: "applying_tracking",
                 application_status: "pending", logistics_channel: channel,
                 shipping_address_snapshot: { "name" => "Amy", "address1" => "1 Rue", "city" => "Paris", "country_code" => "FR", "phone" => "1" })
    oli = create(:order_line_item, order: order)
    create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 1,
           customs_name_zh: "画", customs_name_en: "Painting", declared_value_usd: 10, customs_weight_grams: 100)
    pkg
  end

  it "creates an order and moves to pending_label when the tracking number is immediate" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "true", order_id: "R1", tracking_number: "TN1" }.to_json)
    described_class.new(package).call
    package.reload
    expect(package).to have_state(:pending_label)
    expect(package.application_status).to eq("succeeded")
    expect([ package.raydo_order_id, package.tracking_number ]).to eq([ "R1", "TN1" ])
    expect(package.applied_at).to be_present
  end

  it "stays pending (applying_tracking) and stores order_id when deferred" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "true", order_id: "R2", tracking_number: "", is_delay: "Y" }.to_json)
    described_class.new(package).call
    package.reload
    expect(package).to have_state(:applying_tracking)
    expect(package.application_status).to eq("pending")
    expect(package.raydo_order_id).to eq("R2")
    expect(package.tracking_number).to be_nil
  end

  it "marks failed with the message on ack=false, staying in applying_tracking" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "false", message: "%E5%9C%B0%E5%9D%80%E9%94%99%E8%AF%AF" }.to_json)
    described_class.new(package).call
    package.reload
    expect(package).to have_state(:applying_tracking)
    expect(package.application_status).to eq("failed")
    expect(package.application_message).to eq("地址错误")
  end

  it "polls (does not re-create) when raydo_order_id already exists, succeeding on ready" do
    package.update!(raydo_order_id: "R9", application_status: "failed")
    stub = stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").
      with(query: { order_id: "R9" }).
      to_return(body: { status: "200", order_serveinvoicecode: "SF9", express_type: "SF" }.to_json)
    described_class.new(package).call
    package.reload
    expect(stub).to have_been_requested
    expect(package).to have_state(:pending_label)
    expect(package.tracking_number).to eq("SF9")
    expect(package.carrier).to eq("SF")
  end

  it "leaves the package pending (no fail) when a poll errors transiently" do
    package.update!(raydo_order_id: "R9", application_status: "pending")
    stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").with(query: { order_id: "R9" }).to_timeout
    described_class.new(package).call
    package.reload
    expect(package).to have_state(:applying_tracking)
    expect(package.application_status).to eq("pending")
  end

  it "fails when logistics is not configured" do
    package.update!(logistics_channel: nil)
    described_class.new(package).call
    expect(package.reload.application_status).to eq("failed")
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/package_tracking_applier_spec.rb`
Expected: FAIL — `uninitialized constant PackageTrackingApplier`。

- [ ] **Step 3: Implement the service**

`app/services/package_tracking_applier.rb`：

```ruby
# Applies (or polls) a Raydo tracking number for one package already in
# applying_tracking. On an immediate/deferred/failed create, or a poll of an
# existing order, it updates the package's application_* fields and moves it to
# pending_label on success. Create errors mark failed; poll errors are transient
# (left pending — PollTrackingNumbersJob's 24h cap decides the give-up).
# See docs/superpowers/specs/2026-07-22-order-packing-phase2c-apply-tracking-design.md.
class PackageTrackingApplier
  def initialize(package)
    @package = package
  end

  def call
    channel = @package.logistics_channel
    account = channel&.logistics_account
    return fail!("logistics not configured") if account.nil? || channel.product_id.blank?

    raydo = FulfillmentService.for(account)
    @package.raydo_order_id.present? ? poll(raydo) : create(raydo)
  end

  private

  def create(raydo)
    result = raydo.create_order(@package)
    return fail!(result.message || "order creation failed") unless result.success?

    if result.deferred?
      @package.update!(raydo_order_id: result.order_id, applied_at: Time.current,
                       application_status: "pending", application_message: nil)
    else
      @package.update!(raydo_order_id: result.order_id, tracking_number: result.tracking_number,
                       applied_at: Time.current, application_status: "succeeded", application_message: nil)
      @package.to_label!
    end
  rescue FulfillmentService::Error => e
    fail!(e.message)
  end

  def poll(raydo)
    result = raydo.get_tracking_number(@package.raydo_order_id)
    return unless result.ready? # not out yet — leave pending for the next poll cycle

    @package.update!(tracking_number: result.tracking_number, carrier: result.carrier,
                     application_status: "succeeded", application_message: nil)
    @package.to_label!
  rescue FulfillmentService::Error => e
    # Transient poll failure — do NOT flip to failed; the recurring poller
    # retries, and the 24h cap (PollTrackingNumbersJob) is the give-up.
    Rails.logger.warn("[TrackingApplier] poll Package##{@package.id}: #{e.message}")
  end

  def fail!(message)
    @package.update!(application_status: "failed", application_message: message.to_s.truncate(1000))
    false
  end
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/package_tracking_applier_spec.rb`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add app/services/package_tracking_applier.rb spec/services/package_tracking_applier_spec.rb
git commit -m "feat(packing): PackageTrackingApplier orchestrating create/poll + state"
```

---

### Task 4: Jobs — `ApplyTrackingJob` + `PollTrackingNumbersJob` + recurring

**Files:**
- Create: `app/jobs/apply_tracking_job.rb`, `app/jobs/poll_tracking_numbers_job.rb`
- Modify: `config/recurring.yml`
- Test: `spec/jobs/apply_tracking_job_spec.rb`, `spec/jobs/poll_tracking_numbers_job_spec.rb`

**Interfaces:**
- Consumes: `PackageTrackingApplier`。
- Produces: `ApplyTrackingJob.perform_later(package_id)`；`PollTrackingNumbersJob`（無參數，recurring 每 5 分鐘）；`PollTrackingNumbersJob::GIVE_UP_AFTER = 24.hours`。

- [ ] **Step 1: Write the failing tests**

`spec/jobs/apply_tracking_job_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe ApplyTrackingJob do
  let(:company) { create(:company) }
  let(:store)   { create(:shopify_store, company: company, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", customer_id: "1", customer_userid: "2") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }
  let(:package) do
    order = create(:order, shopify_store: store)
    pkg = create(:package, shopify_store: store, order: order, aasm_state: "applying_tracking",
                 application_status: "pending", logistics_channel: channel,
                 shipping_address_snapshot: { "name" => "A", "address1" => "x", "city" => "P", "country_code" => "FR", "phone" => "1" })
    create(:package_item, package: pkg, order_line_item: create(:order_line_item, order: order), sku: "A", quantity: 1,
           customs_name_en: "Art", customs_name_zh: "画", declared_value_usd: 5, customs_weight_grams: 100)
    pkg
  end

  it "applies for the tracking number of an applying_tracking package" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "true", order_id: "R1", tracking_number: "TN1" }.to_json)
    described_class.perform_now(package.id)
    expect(package.reload).to have_state(:pending_label)
  end

  it "no-ops for a package no longer in applying_tracking" do
    package.update!(aasm_state: "pending_process", application_status: "none")
    described_class.perform_now(package.id)
    expect(WebMock).not_to have_requested(:post, "http://raydo.test:8082/createOrderApi.htm")
  end

  it "no-ops for a missing package id" do
    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end
end
```

`spec/jobs/poll_tracking_numbers_job_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe PollTrackingNumbersJob do
  let(:company) { create(:company) }
  let(:store)   { create(:shopify_store, company: company, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", customer_id: "1", customer_userid: "2") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }

  def pending_package(order_id:, applied_at:)
    order = create(:order, shopify_store: store)
    create(:package, shopify_store: store, order: order, aasm_state: "applying_tracking", application_status: "pending",
           logistics_channel: channel, raydo_order_id: order_id, applied_at: applied_at,
           shipping_address_snapshot: { "name" => "A", "address1" => "x", "city" => "P", "country_code" => "FR", "phone" => "1" })
  end

  it "moves a package to pending_label when the number is now out" do
    pkg = pending_package(order_id: "R1", applied_at: 1.hour.ago)
    stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").with(query: { order_id: "R1" }).
      to_return(body: { status: "200", order_serveinvoicecode: "SF1" }.to_json)
    described_class.perform_now
    expect(pkg.reload).to have_state(:pending_label)
    expect(pkg.tracking_number).to eq("SF1")
  end

  it "gives up (failed) after 24h with a timeout message, without polling" do
    pkg = pending_package(order_id: "R2", applied_at: 25.hours.ago)
    described_class.perform_now
    pkg.reload
    expect(pkg.application_status).to eq("failed")
    expect(pkg.application_message).to eq(I18n.t("packages.apply.timeout"))
    expect(WebMock).not_to have_requested(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm")
  end

  it "leaves a not-yet-out package pending" do
    pkg = pending_package(order_id: "R3", applied_at: 1.hour.ago)
    stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").with(query: { order_id: "R3" }).
      to_return(body: { status: "200", order_serveinvoicecode: "" }.to_json)
    described_class.perform_now
    expect(pkg.reload).to have_state(:applying_tracking)
    expect(pkg.application_status).to eq("pending")
  end

  it "ignores packages without a raydo_order_id" do
    order = create(:order, shopify_store: store)
    create(:package, shopify_store: store, order: order, aasm_state: "applying_tracking", application_status: "pending", raydo_order_id: nil)
    expect { described_class.perform_now }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/jobs/apply_tracking_job_spec.rb spec/jobs/poll_tracking_numbers_job_spec.rb`
Expected: FAIL — `uninitialized constant ApplyTrackingJob`。

- [ ] **Step 3: Implement the jobs**

`app/jobs/apply_tracking_job.rb`：

```ruby
class ApplyTrackingJob < ApplicationJob
  queue_as :default

  # Single-apply and bulk fan-out both enqueue this per package.
  def perform(package_id)
    package = Package.find_by(id: package_id)
    return unless package&.applying_tracking?

    PackageTrackingApplier.new(package).call
  rescue => e
    Rails.logger.error("[ApplyTracking] Package##{package_id}: #{e.class}: #{e.message}")
  end
end
```

`app/jobs/poll_tracking_numbers_job.rb`：

```ruby
class PollTrackingNumbersJob < ApplicationJob
  queue_as :default

  GIVE_UP_AFTER = 24.hours

  # Recurring (every 5 min): poll Raydo for deferred tracking numbers; give up
  # (failed) after GIVE_UP_AFTER. Per-package isolation so one failure can't
  # stall the batch.
  def perform
    Package.where(aasm_state: "applying_tracking", application_status: "pending")
           .where.not(raydo_order_id: [ nil, "" ]).find_each do |package|
      poll_one(package)
    rescue => e
      Rails.logger.error("[PollTracking] Package##{package.id}: #{e.class}: #{e.message}")
    end
  end

  private

  def poll_one(package)
    if package.applied_at.present? && package.applied_at < GIVE_UP_AFTER.ago
      package.update!(application_status: "failed", application_message: I18n.t("packages.apply.timeout"))
      return
    end

    PackageTrackingApplier.new(package).call # order_id present → applier polls
  end
end
```

- [ ] **Step 4: Register the recurring poll job**

在 `config/recurring.yml` 的 **production** 與 **development** 兩段都加入（比照 tracking_refresh）：

```yaml
  poll_tracking_numbers:
    class: PollTrackingNumbersJob
    schedule: every 5 minutes
```

- [ ] **Step 5: Add the timeout i18n key (needed by the job + its spec)**

在三個 locale 檔 `packages:` 下加 `apply.timeout`（zh-TW「货代超时未出号」、en「Carrier did not issue a tracking number in time」、zh-CN「货代超时未出号」）。（其餘 apply/* keys 在 Task 6 補齊；此處先加 job 需要的 timeout，三檔結構一致。）

- [ ] **Step 6: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/jobs/apply_tracking_job_spec.rb spec/jobs/poll_tracking_numbers_job_spec.rb`
Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add app/jobs/apply_tracking_job.rb app/jobs/poll_tracking_numbers_job.rb config/recurring.yml config/locales spec/jobs
git commit -m "feat(packing): ApplyTrackingJob + recurring PollTrackingNumbersJob (24h give-up)"
```

---

### Task 5: Controller `apply_tracking` / `retry_tracking` / `apply_tracking_bulk` + routes

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/packages_controller.rb`
- Create: `app/views/packages/apply_tracking.turbo_stream.erb`
- Test: `spec/requests/packages_spec.rb`

**Interfaces:**
- Consumes: `ApplyTrackingJob`；`Package#ready_for_tracking?`/`#apply_tracking!`。
- Produces: `POST /packages/:id/apply_tracking`（`apply_tracking_package_path`）、`POST /packages/:id/retry_tracking`（`retry_tracking_package_path`）、`POST /packages/apply_tracking_bulk`（`apply_tracking_bulk_packages_path`）。

- [ ] **Step 1: Write the failing request tests**

在 `spec/requests/packages_spec.rb` 新增（沿用檔案 `store`/`customer`/`company`/`sign_in user`；下面自建 account/channel/package）。

> ⚠️ `sign_in_as_member_with` 在該檔是**各 describe 區塊內的區域 `def`**（非全域），所以新 describe **必須自己定義一份**（照該檔既有 3 行寫法），否則 NameError：
> ```ruby
> def sign_in_as_member_with(permission)
>   member = create(:user)
>   create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
>   sign_in member
> end
> ```

```ruby
describe "tracking application" do
  def sign_in_as_member_with(permission)
    member = create(:user)
    create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
    sign_in member
  end

  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", customer_id: "1", customer_userid: "2") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }

  def ready_pkg(state: "pending_process")
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#T1")
    pkg = create(:package, shopify_store: store, order: order, number: 700, aasm_state: state, logistics_channel: channel,
                 shipping_address_snapshot: { "name" => "A", "address1" => "x", "city" => "P", "country_code" => "FR" })
    create(:package_item, package: pkg, order_line_item: create(:order_line_item, order: order), sku: "A", quantity: 1,
           customs_name_en: "Art", customs_name_zh: "画", declared_value_usd: 5, customs_weight_grams: 100)
    pkg
  end

  describe "POST /packages/:id/apply_tracking" do
    it "transitions to applying_tracking (pending) and enqueues the job" do
      pkg = ready_pkg
      expect {
        post apply_tracking_package_path(id: pkg.id), headers: { "Accept" => "text/vnd.turbo-stream.html" }
      }.to have_enqueued_job(ApplyTrackingJob).with(pkg.id)
      expect(response).to have_http_status(:ok)
      pkg.reload
      expect(pkg).to have_state(:applying_tracking)
      expect(pkg.application_status).to eq("pending")
    end

    it "rejects (422) a not-ready package with blockers, without transitioning" do
      pkg = ready_pkg
      pkg.update!(logistics_channel: nil) # not ready: no logistics
      post apply_tracking_package_path(id: pkg.id), headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(pkg.reload).to have_state(:pending_process)
    end

    it "rejects a non-pending_process package" do
      pkg = ready_pkg(state: "pending_review")
      post apply_tracking_package_path(id: pkg.id)
      expect(response).to have_http_status(:found)
      expect(pkg.reload).to have_state(:pending_review)
    end

    it "forbids a member without package_process" do
      pkg = ready_pkg
      sign_in_as_member_with("package_review")
      post apply_tracking_package_path(id: pkg.id)
      expect(response).to have_http_status(:found)
      expect(pkg.reload).to have_state(:pending_process)
    end

    it "404s for another company's package" do
      pkg = ready_pkg
      sign_in create(:user)
      post apply_tracking_package_path(id: pkg.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /packages/:id/retry_tracking" do
    it "re-enqueues the job for a failed applying_tracking package" do
      pkg = ready_pkg(state: "applying_tracking")
      pkg.update!(application_status: "failed", application_message: "boom")
      expect {
        post retry_tracking_package_path(id: pkg.id), headers: { "Accept" => "text/vnd.turbo-stream.html" }
      }.to have_enqueued_job(ApplyTrackingJob).with(pkg.id)
      expect(pkg.reload.application_status).to eq("pending")
    end
  end

  describe "POST /packages/apply_tracking_bulk" do
    it "applies ready packages and skips not-ready ones" do
      ready = ready_pkg
      not_ready = ready_pkg
      not_ready.update!(logistics_channel: nil)
      expect {
        post apply_tracking_bulk_packages_path, params: { package_ids: [ ready.id, not_ready.id ] }
      }.to have_enqueued_job(ApplyTrackingJob).with(ready.id)
      expect(ready.reload).to have_state(:applying_tracking)
      expect(not_ready.reload).to have_state(:pending_process)
    end

    it "forbids a member without package_process" do
      pkg = ready_pkg
      sign_in_as_member_with("package_review")
      post apply_tracking_bulk_packages_path, params: { package_ids: [ pkg.id ] }
      expect(response).to have_http_status(:found)
      expect(pkg.reload).to have_state(:pending_process)
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/packages_spec.rb -e "tracking application"`
Expected: FAIL — `undefined method 'apply_tracking_package_path'`。

- [ ] **Step 3: Add routes**

`config/routes.rb` packages block：

```ruby
    resources :packages, only: [ :index, :show ] do
      member do
        patch :transition
        patch :update_address
        patch :update_item
        patch :update_logistics
        patch :update_note
        post :split
        post :merge
        post :apply_tracking
        post :retry_tracking
      end
      collection do
        post :sync
        post :apply_tracking_bulk
      end
    end
```

- [ ] **Step 4: Add controller actions**

`app/controllers/packages_controller.rb`：把 `before_action :set_package` 的 `only:` 加入 `:apply_tracking, :retry_tracking`。在 `update_note` 之後、`private` 之前加入：

```ruby
  # Apply for a Raydo tracking number (gated on package_process). Blocks a
  # not-ready package (422 + blockers, no transition); a non-pending_process
  # package is rejected before the transition. On success: move to
  # applying_tracking (application_status=pending) and enqueue ApplyTrackingJob.
  def apply_tracking
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    unless @package.pending_process?
      return redirect_to(package_path(id: @package.id), alert: t("packages.apply.invalid_state"))
    end
    unless @package.ready_for_tracking?
      respond_to do |format|
        format.turbo_stream { render :apply_tracking, status: :unprocessable_entity }
        format.html { redirect_to package_path(id: @package.id), alert: t("packages.apply.not_ready") }
      end
      return
    end

    start_application!(@package)
    respond_to do |format|
      format.turbo_stream { render :apply_tracking }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.apply.enqueued") }
    end
  end

  # Retry a failed application (still in applying_tracking). Resets to pending
  # and re-enqueues; the applier is idempotent (polls if an order already
  # exists, else re-creates).
  def retry_tracking
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    unless @package.applying_tracking? && @package.application_status == "failed"
      return redirect_to(package_path(id: @package.id), alert: t("packages.apply.invalid_state"))
    end

    @package.update!(application_status: "pending", application_message: nil)
    ApplyTrackingJob.perform_later(@package.id)
    respond_to do |format|
      format.turbo_stream { render :apply_tracking }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.apply.enqueued") }
    end
  end

  # Bulk apply from the pending_process list. Ready packages are applied +
  # enqueued; not-ready ones are skipped and reported.
  def apply_tracking_bulk
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?

    ids = Array(params[:package_ids]).map(&:to_s)
    candidates = scoped_packages.where(id: ids, aasm_state: "pending_process")
    applied = 0
    skipped = 0
    candidates.find_each do |package|
      if package.ready_for_tracking?
        start_application!(package)
        applied += 1
      else
        skipped += 1
      end
    end
    redirect_to packages_path(state: "pending_process"), notice: t("packages.apply.bulk_result", applied: applied, skipped: skipped)
  end
```

在 `private` 區塊加：

```ruby
  # Move a ready package into applying_tracking (pending) and enqueue the job.
  # applied_at is left nil here — the applier stamps it when Raydo actually
  # creates the order (the correct anchor for the poll give-up).
  def start_application!(package)
    package.apply_tracking!
    package.update!(application_status: "pending", application_message: nil)
    ApplyTrackingJob.perform_later(package.id)
  end
```

- [ ] **Step 5: Add the turbo_stream template**

`app/views/packages/apply_tracking.turbo_stream.erb`（成功/422 都重繪 modal，applying_tracking 狀態與 readiness 交由 modal 內 partial 呈現）：

```erb
<%= turbo_stream.replace "package-modal", partial: "packages/modal", locals: { package: @package.reload } %>
```

- [ ] **Step 6: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/packages_spec.rb -e "tracking application"`
Expected: PASS。（`have_enqueued_job` 需要 test adapter；本專案應已用 `:test` adapter。若整檔其他測試已用 `have_enqueued_job` 則沿用；否則在此 describe 前加 `include ActiveJob::TestHelper` 並確保 `ActiveJob::Base.queue_adapter = :test`。）

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/packages_controller.rb app/views/packages/apply_tracking.turbo_stream.erb spec/requests/packages_spec.rb
git commit -m "feat(packing): apply_tracking / retry_tracking / bulk controller actions + routes"
```

---

### Task 6: UI — 申請/重試 按鈕、applying_tracking 狀態、批量勾選、i18n

**Files:**
- Modify: `app/views/packages/_actions.html.erb`
- Create: `app/views/packages/_application_status.html.erb`
- Modify: `app/views/packages/_modal.html.erb`（插入 application status 區塊）
- Modify: `app/views/packages/index.html.erb`（pending_process 批量表單 + 批次鈕）
- Modify: `app/views/packages/_package_row.html.erb`（pending_process 時的 checkbox）
- Create: `app/javascript/controllers/package_bulk_controller.js`
- Modify: `config/locales/{en,zh-TW,zh-CN}.yml`
- Test:（system 在 Task 7）

**Interfaces:**
- Consumes: `Package#ready_for_tracking?`/`#tracking_blockers`/`application_status`/`tracking_number`/`application_message`；`apply_tracking_package_path`/`retry_tracking_package_path`/`apply_tracking_bulk_packages_path`。

- [ ] **Step 1: Add i18n keys**

在三 locale 檔 `packages:` 下加（示範 zh-TW，另兩檔對應 en / zh-CN；**三檔 key 結構必須相同**；`apply.timeout` 已於 Task 4 加，勿重複）：

```yaml
    apply:
      button: "申请运单号"
      retry: "重试"
      enqueued: "已提交申请，等待货代出号"
      not_ready: "资料不齐全，无法申请运单号"
      invalid_state: "该状态无法申请运单号"
      pending: "申请中，等待货代出号…"
      failed: "申请失败"
      bulk_button: "批量申请运单号"
      bulk_result: "已申请 %{applied} 个，跳过 %{skipped} 个（资料不齐全）"
      tracking_number: "运单号"
    application_status:
      # (all/pending/succeeded/failed 已存在于既有 applying_tracking 分页；如缺则补)
```

- [ ] **Step 2: Add the apply/retry buttons to `_actions`**

在 `app/views/packages/_actions.html.erb` 的 `<div class="flex items-center gap-2">` 內、hold 判斷之後加入（pending_process 齊全顯示申请鈕；不齊全停用；applying_tracking failed 顯示重试）：

```erb
  <% if package.pending_process? && current_membership&.package_process? %>
    <% if package.ready_for_tracking? %>
      <%= button_to t("packages.apply.button"), apply_tracking_package_path(id: package.id),
          method: :post, form: { data: { turbo_frame: "package-modal" } },
          class: "px-4 py-2 bg-indigo-600 text-white text-sm rounded hover:bg-indigo-700" %>
    <% else %>
      <button type="button" disabled title="<%= t('packages.apply.not_ready') %>"
              class="px-4 py-2 bg-gray-200 text-gray-400 text-sm rounded cursor-not-allowed">
        <%= t("packages.apply.button") %>
      </button>
    <% end %>
  <% end %>

  <% if package.applying_tracking? && package.application_status == "failed" && current_membership&.package_process? %>
    <%= button_to t("packages.apply.retry"), retry_tracking_package_path(id: package.id),
        method: :post, form: { data: { turbo_frame: "package-modal" } },
        class: "px-4 py-2 bg-amber-600 text-white text-sm rounded hover:bg-amber-700" %>
  <% end %>
```

- [ ] **Step 3: Add the application-status partial + wire into modal**

`app/views/packages/_application_status.html.erb`：

```erb
<%# Tracking-application state for an applying_tracking package. Stable dom_id
    so the apply/retry turbo_stream (which replaces the whole modal) keeps it
    consistent. %>
<div id="<%= dom_id(package, :application_status) %>">
  <% if package.applying_tracking? %>
    <div class="mx-6 mt-3 px-4 py-2 rounded-md text-sm border
      <%= package.application_status == 'failed' ? 'bg-red-50 text-red-800 border-red-200' : 'bg-blue-50 text-blue-800 border-blue-200' %>">
      <% if package.application_status == "failed" %>
        <p class="font-medium"><%= t("packages.apply.failed") %></p>
        <% if package.application_message.present? %><p class="mt-1"><%= package.application_message %></p><% end %>
      <% else %>
        <p><%= t("packages.apply.pending") %></p>
      <% end %>
    </div>
  <% end %>
  <% if package.tracking_number.present? %>
    <div class="mx-6 mt-3 px-4 py-2 rounded-md bg-green-50 text-green-800 border border-green-200 text-sm">
      <%= t("packages.apply.tracking_number") %>: <span class="font-mono"><%= package.tracking_number %></span>
    </div>
  <% end %>
</div>
```

在 `app/views/packages/_modal.html.erb`，於 `render "packages/readiness"` 之後插入：

```erb
    <%= render "packages/application_status", package: package %>
```

- [ ] **Step 4: Add the bulk Stimulus controller**

`app/javascript/controllers/package_bulk_controller.js`（輕量：勾選任一顯示批次鈕 + 計數；全選）：

```javascript
import { Controller } from "@hotwired/stimulus"

// Lightweight bulk selection for the pending_process packages list. Shows the
// action bar with a live count when at least one row is checked.
export default class extends Controller {
  static targets = ["checkbox", "bar", "count", "all"]

  refresh() {
    const n = this.checkboxTargets.filter((c) => c.checked).length
    if (this.hasCountTarget) this.countTarget.textContent = n
    if (this.hasBarTarget) this.barTarget.classList.toggle("hidden", n === 0)
  }

  toggleAll(event) {
    this.checkboxTargets.forEach((c) => { c.checked = event.target.checked })
    this.refresh()
  }
}
```

- [ ] **Step 5: Wrap the pending_process list in the bulk form + add checkboxes**

在 `app/views/packages/index.html.erb`：當 `@state == "pending_process"` 時，用 `form_with url: apply_tracking_bulk_packages_path, method: :post` 包住表格並套 `data-controller="package_bulk"`，表頭加一欄全選、加一條批次鈕 bar；`_package_row` 在 pending_process 時第一欄加 checkbox（`name="package_ids[]"`, `value=package.id`, `data-package-bulk-target="checkbox"`, `data-action="change->package_bulk#refresh"`）。

index.html.erb（table 外層改寫，僅 pending_process 加 form/controller/bar；其他 state 維持原樣）：

```erb
  <% bulk = (@state == "pending_process") %>
  <%= form_with url: apply_tracking_bulk_packages_path, method: :post,
        data: (bulk ? { controller: "package_bulk" } : {}), html: { id: "packages-bulk-form" } do %>
    <% if bulk %>
      <div data-package-bulk-target="bar" class="hidden mb-3 flex items-center gap-3 px-4 py-2 bg-indigo-50 border border-indigo-200 rounded">
        <span class="text-sm text-indigo-800"><%= t("packages.apply.bulk_button") %> · <span data-package-bulk-target="count">0</span></span>
        <%= submit_tag t("packages.apply.bulk_button"), class: "px-3 py-1.5 text-sm bg-indigo-600 text-white rounded hover:bg-indigo-700 cursor-pointer" %>
      </div>
    <% end %>
    <div class="bg-white rounded-lg border border-gray-200 overflow-hidden">
      <div class="overflow-x-auto">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <% if bulk %><th class="px-4 py-3"><input type="checkbox" data-action="change->package_bulk#toggleAll" data-package-bulk-target="all"></th><% end %>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase"><%= t("packages.columns.package_code") %></th>
              <%# ...其余表头列保持不变... %>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <% if @packages.empty? %>
              <tr><td colspan="<%= bulk ? 9 : 8 %>" class="px-4 py-8 text-center text-sm text-gray-500"><%= t("packages.no_packages") %></td></tr>
            <% else %>
              <% @packages.each do |package| %>
                <%= render "packages/package_row", package: package, bulk: bulk %>
              <% end %>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
  <% end %>
```

`_package_row.html.erb` 開頭 `<tr>` 之後加（用 `local_assigns` 讓 bulk 為選填，其他呼叫端不傳也不炸）：

```erb
<tr>
  <% if local_assigns[:bulk] %>
    <td class="px-4 py-3 align-top">
      <input type="checkbox" name="package_ids[]" value="<%= package.id %>"
             data-package-bulk-target="checkbox" data-action="change->package_bulk#refresh">
    </td>
  <% end %>
```

> 注意：`_package_row` 也被 `index` 以外處呼叫的話（本專案僅 index 用），保持 `local_assigns[:bulk]` 選填即可。表头「其余列保持不变」处：实作时把现有 7 个 `<th>` 原样保留，仅在最前面按 `bulk` 插入勾选栏。

- [ ] **Step 6: Sanity checks**

Run:
```
PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rails runner "%w[en zh-TW zh-CN].each { |l| I18n.locale=l; %w[packages.apply.button packages.apply.retry packages.apply.pending packages.apply.failed packages.apply.bulk_button packages.apply.bulk_result packages.apply.timeout].each { |k| raise \"missing #{k} in #{l}\" unless I18n.exists?(k) } }; puts 'i18n ok'"
PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/packages_spec.rb
```
Expected: 「i18n ok」；request spec 全綠（modal 現在多渲染 application_status partial，語法錯會在此浮現）。RuboCop 乾淨（`bin/rubocop`）。

- [ ] **Step 7: Commit**

```bash
git add app/views/packages app/javascript/controllers/package_bulk_controller.js config/locales
git commit -m "feat(packing): apply/retry buttons, applying_tracking status, bulk select UI + i18n"
```

---

### Task 7: System specs（真 Chrome）

**Files:**
- Modify: `spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: Task 1–6 全部。

- [ ] **Step 1: Write the system tests**

在 `spec/system/packages_spec.rb` 新增（沿用 `sign_in_as(user)` 與既有 `let`；WebMock 在 system 亦生效，stub Raydo）：

```ruby
describe "申请运单号" do
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", customer_id: "1", customer_userid: "2") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }

  def ready_pkg
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#APP1")
    pkg = create(:package, shopify_store: store, order: order, number: 800, aasm_state: "pending_process", logistics_channel: channel,
                 shipping_address_snapshot: { "name" => "A", "address1" => "x", "city" => "P", "country_code" => "FR" })
    create(:package_item, package: pkg, order_line_item: create(:order_line_item, order: order), sku: "A", quantity: 1,
           customs_name_en: "Art", customs_name_zh: "画", declared_value_usd: 5, customs_weight_grams: 100)
    pkg
  end

  it "applies for a tracking number and shows the applying state" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "true", order_id: "R1", tracking_number: "TN1" }.to_json)
    pkg = ready_pkg
    visit packages_path(state: "pending_process")
    click_link pkg.package_code
    expect(page).to have_button(I18n.t("packages.apply.button"))
    click_button I18n.t("packages.apply.button")
    # job runs inline in system tests only if adapter executes; assert the state transition + tracking number surfaced via reload
    expect(pkg.reload.aasm_state).to eq("applying_tracking").or eq("pending_label")
  end

  it "disables the apply button when the package is not ready" do
    pkg = ready_pkg
    pkg.update!(logistics_channel: nil)
    visit packages_path(state: "pending_process")
    click_link pkg.package_code
    expect(page).to have_button(I18n.t("packages.apply.button"), disabled: true)
  end

  it "shows a bulk apply bar when a pending_process row is checked" do
    ready_pkg
    visit packages_path(state: "pending_process")
    first("input[name='package_ids[]']").check
    expect(page).to have_button(I18n.t("packages.apply.bulk_button"))
  end
end
```

> 注意：system test 的 job 執行取決於 queue adapter。若 apply 後看不到 applying_tracking→pending_label 的即時變化，斷言以「transition 到 applying_tracking」為主（controller 同步做的部分），job 的結果不強求在同一頁即時反映（避免 adapter 相依的 flaky）。若本機 chromedriver 超前 Chrome，依 [[local-system-test-chromedriver]] 把 `/tmp/chromedriver-linux64` 前置 PATH。

- [ ] **Step 2: Run to verify**

Run: `PATH=/tmp/chromedriver-linux64:/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/system/packages_spec.rb -e "申请运单号"`
Expected: PASS（3 例）。

- [ ] **Step 3: Commit**

```bash
git add spec/system/packages_spec.rb
git commit -m "test(packing): system specs for apply-tracking flow + bulk bar"
```

---

### Task 8: 全套驗證 + PR

**Files:** 無新增。

- [ ] **Step 1: Full suite**

Run: `PATH=/tmp/chromedriver-linux64:/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec`
Expected: 全綠、coverage ≥ 95%。系統測試若有既知 timing-flaky（[[flaky-system-tests]]），重跑失敗例確認 flaky vs real；2C 程式碼的真實失敗須停下修正。

- [ ] **Step 2: Lint + security**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rubocop && bin/brakeman --no-pager`
Expected: RuboCop 0 offense；Brakeman 無新警告（留意 createOrder 的 payload 建構與 params[:package_ids] 處理；package_ids 只用於 `scoped_packages.where(id:)` 查詢，非 mass-assignment）。

- [ ] **Step 3: Push + PR to staging**

```bash
git push -u origin feature/order-packing-phase2c
```
用 `gh pr create --base staging`（標題 `feat(packing): Phase 2C 申请运单号`，內文列 Q1–Q6 決策、混合同步/非同步流程、24h 輪詢、測試涵蓋、以及 weight 單位待向货代確認的假設）。PR 內文結尾加：
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`

---

## Self-Review（對照 spec）

- **Spec 覆蓋**：5 欄+back_to_process 清空→T1；Raydo create_order/get_tracking_number 三分支+映射→T2；PackageTrackingApplier 編排/冪等/錯誤分流→T3；ApplyTrackingJob+PollTrackingNumbersJob(5min/24h)+recurring→T4；controller apply/retry/bulk+routes+權限/422/404→T5；UI 申請/重試/狀態/批量+i18n→T6；system→T7；驗證/PR→T8。全部有對應任務。
- **Placeholder 掃描**：無 TBD/TODO；每個 code step 附完整程式碼與指令。weight 單位以 `WEIGHT_DIVISOR` 常數 + 註解標示「向货代確認」，非 placeholder。
- **型別一致**：`Raydo#create_order → CreateResult(success?/order_id/tracking_number/deferred?/message)`、`#get_tracking_number → TrackResult(ready?/tracking_number/carrier/message)`、`PackageTrackingApplier.new(package).call`、`ApplyTrackingJob.perform_later(package_id)`、`PollTrackingNumbersJob::GIVE_UP_AFTER`、route helpers `apply_tracking_package_path`/`retry_tracking_package_path`/`apply_tracking_bulk_packages_path`、Stimulus targets（checkbox/bar/count/all）在 T5/T6 一致。
- **執行時需對齊處**（已就地標註）：request/system 的 `have_enqueued_job` 需 `:test` queue adapter（沿用檔案既有慣例）；`_actions`/`_modal`/`index`/`_package_row` 為非 strict-locals，`local_assigns[:bulk]` 選填安全（注意 [[erb-strict-locals-magic-comment]]）；Raydo 檔避免雙 `private` 區塊；i18n `apply.timeout` 於 T4 先加、T6 勿重複。
