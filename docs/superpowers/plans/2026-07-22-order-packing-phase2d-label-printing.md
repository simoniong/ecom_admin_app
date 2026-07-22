# 訂單打包 Phase 2D — 印面單 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓操作者對 `pending_label` 且有 `raydo_order_id` 的包裹（單筆或批量同類型）向華磊 URL2 抓 PDF 面單，於瀏覽器 inline 開啟列印；無狀態變更、可重印。

**Architecture:** `FulfillmentService::Raydo#label_pdf`（打 URL2 `PDF_NEW.aspx`，回二進位 PDF）；`PackageLabelPrinter` 驗證一組包裹並取合併 PDF；controller `label`/`labels` 以 `send_data`（inline）proxy 串流，gate 於 `package_shipping?`。`PrintType` 存於 `LogisticsChannel#label_print_type`。

**Tech Stack:** Rails 8.1、HTTParty、Hotwire(Turbo+Stimulus)、Tailwind、PostgreSQL(UUID)、RSpec + FactoryBot + WebMock。

## Global Constraints

- 所有 table id 用 UUID。
- 測試：RSpec + FactoryBot，**不 mock DB、打真 DB、95%+ line coverage**；外部 HTTP 一律用 **WebMock `stub_request`**。每功能 model/service + request + system。
- 絕不 commit 到 `staging`/`main`；在 `feature/order-packing-phase2d-label` 上做（**疊在 `feature/order-packing-phase2c` 上**；推送用 `git push -u origin feature/order-packing-phase2d-label`）。
- 印面單只取 PDF、**無 AASM 狀態變更、可重印**；印面單與發貨(ship)是獨立操作。
- 權限 gate：`label`/`labels` 用 `current_membership&.package_shipping?`（owner 通過）。每個寫入/讀取 action 先 scoped（`set_package`→跨公司 404 / `scoped_packages.where`→過濾）。失敗一律 redirect + alert（回傳 PDF 無法夾帶錯誤），**絕不 500**。
- 外部 API 錯誤：只露 exception class（沿用既有 raydo.rb 紀律）；華磊列印 URL 不帶帳密，但仍走伺服器 proxy、不把 url2_base/order_id 暴露前端。
- Ruby toolchain：跑 rspec/rails 前 PATH 前置 `/home/simon/.rubies/ruby-3.4.7/bin`。單檔 rspec 因 SimpleCov 可能 exit 2（看「N examples, 0 failures」）。
- 批量僅在選取包裹**同一 `label_print_type`** 時成立；跨類型 → 拒絕（不加 PDF 合併相依）。
- 華磊 API 參考：`docs/superpowers/references/raydo-huali-api.md`。

---

## File Structure

- **Migration** `db/migrate/*_add_label_print_type_to_logistics_channels.rb`（新增）。
- **`app/models/logistics_channel.rb`**（改）— `label_print_type` presence 驗證。
- **`app/models/membership.rb`**（改）— 新增 `package_shipping?`。
- **`app/services/fulfillment_service/raydo.rb`**（改）— `label_pdf`。
- **`app/services/package_label_printer.rb`**（新增）。
- **`app/controllers/packages_controller.rb`**（改）— `label` / `labels` + `label_error_message`。
- **`app/controllers/logistics_channels_controller.rb`**（改）— permit `label_print_type`。
- **`config/routes.rb`**（改）— member `get :label`；collection `post :labels`。
- **Views**：`_actions.html.erb`（印面单鈕）、`index.html.erb`（pending_label 批量表單一般化）、`logistics_channels/_form.html.erb`（label_print_type 欄位）。
- **i18n** `config/locales/{en,zh-TW,zh-CN}.yml`（改）。
- **Specs**：`spec/models/logistics_channel_spec.rb`、`spec/models/membership_spec.rb`、`spec/services/fulfillment_service/raydo_spec.rb`、`spec/services/package_label_printer_spec.rb`（新）、`spec/requests/packages_spec.rb`、`spec/requests/logistics_channels_spec.rb`、`spec/system/packages_spec.rb`。

**共用測試前置**（各 spec 沿用現有慣例）：

```ruby
let(:user)     { create(:user) }
let(:company)  { user.companies.first }
let(:store)    { create(:shopify_store, user: user, company: company, package_prefix: "XMBDE", package_number_start: 2013094) }
let(:customer) { create(:customer, shopify_store: store) }
let(:account)  { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089", customer_id: "1", customer_userid: "2") }
let(:channel)  { create(:logistics_channel, logistics_account: account, product_id: "P1", label_print_type: "lab10_10") }

def label_ready_package(number: 900, print_channel: channel)
  order = create(:order, customer: customer, shopify_store: store)
  create(:package, shopify_store: store, order: order, number: number, aasm_state: "pending_label",
         logistics_channel: print_channel, raydo_order_id: "R#{number}", tracking_number: "TN#{number}")
end

PDF_BYTES = "%PDF-1.4\n%mock label\n%%EOF"
```

---

### Task 1: 基礎 — migration + channel 驗證 + `Membership#package_shipping?`

**Files:**
- Create: `db/migrate/YYYYMMDDHHMMSS_add_label_print_type_to_logistics_channels.rb`
- Modify: `db/schema.rb`（migrate 產生）
- Modify: `app/models/logistics_channel.rb`, `app/models/membership.rb`
- Test: `spec/models/logistics_channel_spec.rb`, `spec/models/membership_spec.rb`

**Interfaces:**
- Produces: `logistics_channels.label_print_type`(string, default `"lab10_10"`, null:false); `LogisticsChannel` 驗證 presence; `Membership#package_shipping?` → Boolean（`owner? || permissions.include?("package_shipping")`）。

- [ ] **Step 1: Write the failing tests**

`spec/models/logistics_channel_spec.rb`（新增或補；沿用該檔既有慣例，若無則新建 file 開頭 `require "rails_helper"`）：

```ruby
describe "label_print_type" do
  it "defaults to lab10_10" do
    expect(create(:logistics_channel).label_print_type).to eq("lab10_10")
  end

  it "is required" do
    channel = build(:logistics_channel, label_print_type: "")
    expect(channel).not_to be_valid
    expect(channel.errors[:label_print_type]).to be_present
  end
end
```

`spec/models/membership_spec.rb`（新增）：

```ruby
describe "#package_shipping?" do
  let(:company) { create(:company) }

  it "is true for an owner" do
    m = create(:membership, company: company, user: create(:user), role: :owner)
    expect(m.package_shipping?).to be(true)
  end

  it "is true for a member granted package_shipping" do
    m = create(:membership, :member_with_group, company: company, user: create(:user), permissions: [ "package_shipping" ])
    expect(m.package_shipping?).to be(true)
  end

  it "is false for a member without it" do
    m = create(:membership, :member_with_group, company: company, user: create(:user), permissions: [ "package_process" ])
    expect(m.package_shipping?).to be(false)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/models/logistics_channel_spec.rb spec/models/membership_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'label_print_type'` / `undefined method 'package_shipping?'`。

- [ ] **Step 3: Migration + model changes**

`bin/rails g migration AddLabelPrintTypeToLogisticsChannels` 後貼入：

```ruby
class AddLabelPrintTypeToLogisticsChannels < ActiveRecord::Migration[8.1]
  def change
    add_column :logistics_channels, :label_print_type, :string, null: false, default: "lab10_10"
  end
end
```

`app/models/logistics_channel.rb` 加驗證（與既有 validates 並列）：

```ruby
  validates :label_print_type, presence: true
```

`app/models/membership.rb`，在 `package_process?` 之後加：

```ruby
  def package_shipping?
    owner? || permissions.include?("package_shipping")
  end
```

- [ ] **Step 4: Migrate + run**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rails db:migrate && bin/rails db:test:prepare && bundle exec rspec spec/models/logistics_channel_spec.rb spec/models/membership_spec.rb`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add db/migrate db/schema.rb app/models/logistics_channel.rb app/models/membership.rb spec/models/logistics_channel_spec.rb spec/models/membership_spec.rb
git commit -m "feat(packing): add label_print_type to channels + Membership#package_shipping?"
```

---

### Task 2: `FulfillmentService::Raydo#label_pdf`

**Files:**
- Modify: `app/services/fulfillment_service/raydo.rb`
- Test: `spec/services/fulfillment_service/raydo_spec.rb`

**Interfaces:**
- Consumes: `LogisticsAccount#url2_base`。
- Produces: `Raydo#label_pdf(order_ids, print_type) → String`（PDF bytes）；失敗 raise `FulfillmentService::Error`。

- [ ] **Step 1: Write the failing tests**

在 `spec/services/fulfillment_service/raydo_spec.rb` 新增：

```ruby
describe "#label_pdf" do
  let(:account) { create(:logistics_account, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089") }

  it "fetches the combined PDF for the given order ids and print type" do
    stub = stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").
      with(query: { "PrintType" => "lab10_10", "order_id" => "R1,R2" }).
      to_return(body: "%PDF-1.4\nlabel", headers: { "Content-Type" => "application/pdf" })
    pdf = described_class.new(account).label_pdf([ "R1", "R2" ], "lab10_10")
    expect(pdf).to start_with("%PDF")
    expect(stub).to have_been_requested
  end

  it "raises when url2_base is not configured" do
    account.update!(url2_base: nil)
    expect { described_class.new(account).label_pdf([ "R1" ], "lab10_10") }.to raise_error(FulfillmentService::Error, /URL2/)
  end

  it "raises on a non-PDF (HTML error page) response" do
    stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").with(query: hash_including({})).
      to_return(body: "<html>error: order not found</html>", headers: { "Content-Type" => "text/html" })
    expect { described_class.new(account).label_pdf([ "R1" ], "lab10_10") }.to raise_error(FulfillmentService::Error, /non-PDF/)
  end

  it "raises on an HTTP error status" do
    stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").with(query: hash_including({})).
      to_return(status: 500, body: "err")
    expect { described_class.new(account).label_pdf([ "R1" ], "lab10_10") }.to raise_error(FulfillmentService::Error, /HTTP 500/)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/fulfillment_service/raydo_spec.rb -e label_pdf`
Expected: FAIL — `NoMethodError: undefined method 'label_pdf'`。

- [ ] **Step 3: Implement**

在 `app/services/fulfillment_service/raydo.rb` 的 `class Raydo` 內、既有 public 方法之後（`private` 之前）加入：

```ruby
    # GET url2/order/FastRpt/PDF_NEW.aspx?PrintType=&order_id=<comma-joined>
    # Returns raw PDF bytes. Uses url2_base (label server) and does NOT parse the
    # body as JSON. Raydo returns an HTML error page on failure, so we require a
    # %PDF magic prefix. The print URL carries no credentials, but we keep the
    # same credential-safe error discipline (class-only messages).
    def label_pdf(order_ids, print_type)
      raise FulfillmentService::Error, "Raydo URL2 base is not configured" if @account.url2_base.blank?

      base = @account.url2_base.to_s.chomp("/")
      resp = HTTParty.get("#{base}/order/FastRpt/PDF_NEW.aspx",
                          query: { PrintType: print_type, order_id: Array(order_ids).join(",") },
                          timeout: 30)
      raise FulfillmentService::Error, "Raydo HTTP #{resp.code}" unless resp.success?

      body = resp.body.to_s
      raise FulfillmentService::Error, "Raydo returned a non-PDF label response" unless body.start_with?("%PDF")

      body
    rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, IO::TimeoutError, Timeout::Error, SocketError, SystemCallError => e
      raise FulfillmentService::Error, "Raydo connection failed (#{e.class})"
    rescue URI::InvalidURIError, ArgumentError => e
      raise FulfillmentService::Error, "Raydo request failed (#{e.class})"
    end
```

- [ ] **Step 4: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/fulfillment_service/raydo_spec.rb`
Expected: PASS（新測試 + 既有全綠）。

- [ ] **Step 5: Commit**

```bash
git add app/services/fulfillment_service/raydo.rb spec/services/fulfillment_service/raydo_spec.rb
git commit -m "feat(packing): Raydo#label_pdf fetches URL2 label PDF"
```

---

### Task 3: `PackageLabelPrinter` service

**Files:**
- Create: `app/services/package_label_printer.rb`
- Test: `spec/services/package_label_printer_spec.rb`

**Interfaces:**
- Consumes: `Raydo#label_pdf`；`Package#pending_label?`/`#raydo_order_id`/`#logistics_channel`/`#package_code`；`LogisticsChannel#label_print_type`/`#logistics_account`。
- Produces: `PackageLabelPrinter.new(packages).call → Result(success?, pdf, filename, error)`。`error` 為 symbol（`:empty` `:invalid_state` `:no_order` `:no_channel` `:mixed_type` `:url2_missing`）或華磊錯誤字串。

- [ ] **Step 1: Write the failing tests**

`spec/services/package_label_printer_spec.rb`（沿用上方共用前置的 factory 概念，自建於檔內）：

```ruby
require "rails_helper"

RSpec.describe PackageLabelPrinter do
  let(:user)     { create(:user) }
  let(:company)  { user.companies.first }
  let(:store)    { create(:shopify_store, company: company, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:account)  { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089") }
  let(:channel)  { create(:logistics_channel, logistics_account: account, product_id: "P1", label_print_type: "lab10_10") }

  def pkg(number:, state: "pending_label", order_id: "R#{number}", chan: channel)
    order = create(:order, shopify_store: store)
    create(:package, shopify_store: store, order: order, number: number, aasm_state: state,
           logistics_channel: chan, raydo_order_id: order_id)
  end

  it "fetches a combined PDF for same-type packages" do
    stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").
      with(query: { "PrintType" => "lab10_10", "order_id" => "R1,R2" }).
      to_return(body: "%PDF-1.4\nlabels", headers: { "Content-Type" => "application/pdf" })
    result = described_class.new([ pkg(number: 1), pkg(number: 2) ]).call
    expect(result.success?).to be(true)
    expect(result.pdf).to start_with("%PDF")
    expect(result.filename).to eq("labels_2.pdf")
  end

  it "uses the package_code in the filename for a single package" do
    p = pkg(number: 1)
    stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").with(query: hash_including({})).
      to_return(body: "%PDF-1.4", headers: { "Content-Type" => "application/pdf" })
    expect(described_class.new([ p ]).call.filename).to eq("label_#{p.package_code}.pdf")
  end

  it "fails on empty input" do
    expect(described_class.new([]).call.error).to eq(:empty)
  end

  it "fails when a package is not pending_label" do
    expect(described_class.new([ pkg(number: 1, state: "applying_tracking") ]).call.error).to eq(:invalid_state)
  end

  it "fails when a package has no raydo_order_id" do
    expect(described_class.new([ pkg(number: 1, order_id: nil) ]).call.error).to eq(:no_order)
  end

  it "fails on mixed label_print_type" do
    other = create(:logistics_channel, logistics_account: account, product_id: "P2", label_print_type: "A4")
    result = described_class.new([ pkg(number: 1), pkg(number: 2, chan: other) ]).call
    expect(result.error).to eq(:mixed_type)
  end

  it "fails when url2_base is missing" do
    account.update!(url2_base: nil)
    expect(described_class.new([ pkg(number: 1) ]).call.error).to eq(:url2_missing)
  end

  it "wraps a Raydo error as a failure result" do
    stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").with(query: hash_including({})).
      to_return(status: 500, body: "err")
    result = described_class.new([ pkg(number: 1) ]).call
    expect(result.success?).to be(false)
    expect(result.error).to be_a(String)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/package_label_printer_spec.rb`
Expected: FAIL — `uninitialized constant PackageLabelPrinter`。

- [ ] **Step 3: Implement**

`app/services/package_label_printer.rb`：

```ruby
# Validates a set of pending_label packages and fetches their combined Raydo
# label PDF (one carrier request; Raydo merges multiple order_ids into one PDF).
# Batch requires a single label_print_type (no PDF-merge dependency).
# See docs/superpowers/specs/2026-07-22-order-packing-phase2d-label-printing-design.md.
class PackageLabelPrinter
  Result = Struct.new(:success, :pdf, :filename, :error, keyword_init: true) do
    def success? = !!success
  end

  def initialize(packages)
    @packages = Array(packages)
  end

  def call
    return failure(:empty) if @packages.empty?
    return failure(:invalid_state) unless @packages.all?(&:pending_label?)
    return failure(:no_order) unless @packages.all? { |p| p.raydo_order_id.present? }

    channels = @packages.map(&:logistics_channel)
    return failure(:no_channel) if channels.any?(&:nil?)

    types = channels.map(&:label_print_type).uniq
    return failure(:mixed_type) if types.size > 1

    account = channels.first.logistics_account
    return failure(:url2_missing) if account.url2_base.blank?

    pdf = FulfillmentService.for(account).label_pdf(@packages.map(&:raydo_order_id), types.first)
    Result.new(success: true, pdf: pdf, filename: filename)
  rescue FulfillmentService::Error => e
    failure(e.message)
  end

  private

  def filename
    if @packages.size == 1
      "label_#{@packages.first.package_code}.pdf"
    else
      "labels_#{@packages.size}.pdf"
    end
  end

  def failure(error)
    Result.new(success: false, error: error)
  end
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/package_label_printer_spec.rb`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add app/services/package_label_printer.rb spec/services/package_label_printer_spec.rb
git commit -m "feat(packing): PackageLabelPrinter validates + fetches combined label PDF"
```

---

### Task 4: Controller `label` / `labels` + routes

**Files:**
- Modify: `config/routes.rb`, `app/controllers/packages_controller.rb`
- Test: `spec/requests/packages_spec.rb`

**Interfaces:**
- Consumes: `PackageLabelPrinter`。
- Produces: `GET /packages/:id/label`（`label_package_path`）、`POST /packages/labels`（`labels_packages_path`）。成功 `send_data` PDF (inline)；失敗 redirect + alert。

- [ ] **Step 1: Write the failing request tests**

在 `spec/requests/packages_spec.rb` 新增（沿用檔案 `store`/`customer`/`company`/`sign_in user`；新 describe 自建 `sign_in_as_member_with`——它在該檔是區塊區域 helper，非全域）：

```ruby
describe "label printing" do
  def sign_in_as_member_with(permission)
    member = create(:user)
    create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
    sign_in member
  end

  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089", customer_id: "1", customer_userid: "2") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1", label_print_type: "lab10_10") }

  def label_pkg(number: 900, order_id: "R900", chan: channel, state: "pending_label")
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#L#{number}")
    create(:package, shopify_store: store, order: order, number: number, aasm_state: state, logistics_channel: chan, raydo_order_id: order_id)
  end

  def stub_label(order_ids: "R900", type: "lab10_10")
    stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").
      with(query: { "PrintType" => type, "order_id" => order_ids }).
      to_return(body: "%PDF-1.4\nlabel", headers: { "Content-Type" => "application/pdf" })
  end

  describe "GET /packages/:id/label" do
    it "streams the label PDF inline" do
      pkg = label_pkg
      stub_label(order_ids: pkg.raydo_order_id)
      get label_package_path(id: pkg.id)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("inline")
      expect(response.body).to start_with("%PDF")
    end

    it "redirects with an alert when Raydo errors" do
      pkg = label_pkg
      stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").with(query: hash_including({})).to_return(status: 500, body: "e")
      get label_package_path(id: pkg.id)
      expect(response).to have_http_status(:found)
    end

    it "redirects for a non-pending_label package" do
      pkg = label_pkg(state: "pending_process")
      get label_package_path(id: pkg.id)
      expect(response).to have_http_status(:found)
    end

    it "forbids a member without package_shipping" do
      pkg = label_pkg
      sign_in_as_member_with("package_process")
      get label_package_path(id: pkg.id)
      expect(response).to have_http_status(:found)
    end

    it "404s for another company's package" do
      pkg = label_pkg
      sign_in create(:user)
      get label_package_path(id: pkg.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /packages/labels" do
    it "streams a combined PDF for same-type packages" do
      a = label_pkg(number: 901, order_id: "R901")
      b = label_pkg(number: 902, order_id: "R902")
      stub_label(order_ids: "R901,R902")
      post labels_packages_path, params: { package_ids: [ a.id, b.id ] }
      expect(response.media_type).to eq("application/pdf")
      expect(response.body).to start_with("%PDF")
    end

    it "redirects with alert on mixed label types" do
      other = create(:logistics_channel, logistics_account: account, product_id: "P2", label_print_type: "A4")
      a = label_pkg(number: 901, order_id: "R901")
      b = label_pkg(number: 902, order_id: "R902", chan: other)
      post labels_packages_path, params: { package_ids: [ a.id, b.id ] }
      expect(response).to have_http_status(:found)
    end

    it "forbids a member without package_shipping" do
      pkg = label_pkg
      sign_in_as_member_with("package_process")
      post labels_packages_path, params: { package_ids: [ pkg.id ] }
      expect(response).to have_http_status(:found)
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/packages_spec.rb -e "label printing"`
Expected: FAIL — `undefined method 'label_package_path'`。

- [ ] **Step 3: Add routes**

`config/routes.rb` packages block：member 加 `get :label`；collection 加 `post :labels`：

```ruby
      member do
        # ...existing...
        get :label
      end
      collection do
        # ...existing (sync, apply_tracking_bulk)...
        post :labels
      end
```

- [ ] **Step 4: Add controller actions**

`app/controllers/packages_controller.rb`：把 `set_package` 的 `only:` 加入 `:label`。在 `apply_tracking_bulk` 之後、`private` 之前加：

```ruby
  # Stream the Raydo label PDF for one pending_label package (gated on
  # package_shipping). No state change — labels are re-printable. On any failure
  # we can't embed an error in a PDF response, so redirect back with an alert.
  def label
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_shipping?

    result = PackageLabelPrinter.new([ @package ]).call
    if result.success?
      send_data result.pdf, type: "application/pdf", disposition: "inline", filename: result.filename
    else
      redirect_to packages_path(state: "pending_label"), alert: label_error_message(result.error)
    end
  end

  # Bulk label print: one combined PDF for the selected pending_label packages
  # (must share a label_print_type). Gated on package_shipping.
  def labels
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_shipping?

    ids = Array(params[:package_ids]).map(&:to_s)
    packages = scoped_packages.where(id: ids, aasm_state: "pending_label").to_a
    result = PackageLabelPrinter.new(packages).call
    if result.success?
      send_data result.pdf, type: "application/pdf", disposition: "inline", filename: result.filename
    else
      redirect_to packages_path(state: "pending_label"), alert: label_error_message(result.error)
    end
  end
```

在 `private` 區塊加：

```ruby
  # Map a PackageLabelPrinter failure (symbol for a validation reason, or a raw
  # Raydo error string) to a user-facing flash. Unknown/raw errors fall back to
  # the generic "failed" message (never surfaces a raw carrier string verbatim).
  def label_error_message(error)
    key = error.is_a?(Symbol) ? error : :failed
    t("packages.label.errors.#{key}", default: t("packages.label.errors.failed"))
  end
```

- [ ] **Step 5: Run to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/packages_spec.rb -e "label printing"`
Expected: PASS。（此時 i18n `packages.label.*` 尚未加——`t(..., default:)` 有 default 不會炸，但缺 key 會顯示 default 或 translation-missing；Task 5 補齊。若 request spec 對 alert 文字有斷言則需先加 key——上面測試只斷言 status，安全。）

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/packages_controller.rb spec/requests/packages_spec.rb
git commit -m "feat(packing): label / labels controller actions stream Raydo PDF inline"
```

---

### Task 5: UI — 印面单 鈕、批量表單、渠道 label_print_type 欄位、i18n

**Files:**
- Modify: `app/views/packages/_actions.html.erb`
- Modify: `app/views/packages/index.html.erb`
- Modify: `app/views/logistics_channels/_form.html.erb`
- Modify: `app/controllers/logistics_channels_controller.rb`（permit）
- Modify: `config/locales/{en,zh-TW,zh-CN}.yml`
- Test:（system 在 Task 6；channel form 在 Task 6 request/system）

**Interfaces:**
- Consumes: `label_package_path`/`labels_packages_path`；`Package#pending_label?`；`current_membership&.package_shipping?`。

- [ ] **Step 1: Add i18n keys**

三 locale 檔 `packages:` 下加（示範 zh-TW **繁體**；zh-CN 简体；en 英；三檔結構一致）：

```yaml
    label:
      button: "打印面单"          # zh-TW: 列印面單
      bulk_button: "批量打印面单"  # zh-TW: 批量列印面單
      errors:
        empty: "未选择包裹"
        invalid_state: "只有待打单的包裹可以打印面单"
        no_order: "包裹尚无运单号，无法打印面单"
        no_channel: "包裹未指派物流渠道"
        mixed_type: "所选包裹的标签类型不一致，请选择同一种标签类型"
        url2_missing: "尚未配置货代打印地址(URL2)"
        failed: "获取面单失败，请稍后重试"
```

`logistics_channels:` 下加：
```yaml
    label_print_type: "标签打印类型"   # zh-TW: 標籤列印類型
```

> zh-TW 全部用繁體（打印→列印、单→單、货代→貨代 等）；zh-CN 用简体；en 對應英文。三檔 key 結構必須相同（CI 會查）。

- [ ] **Step 2: Add the 印面单 button to `_actions`**

在 `app/views/packages/_actions.html.erb` 的 `<div class="flex items-center gap-2">` 內、末尾（retry 判斷之後）加入：

```erb
  <% if package.pending_label? && current_membership&.package_shipping? %>
    <%= link_to t("packages.label.button"), label_package_path(id: package.id),
        target: "_blank", rel: "noopener",
        class: "px-4 py-2 bg-teal-600 text-white text-sm rounded hover:bg-teal-700 no-underline" %>
  <% end %>
```

- [ ] **Step 3: Add label_print_type to the channel form + permit**

`app/controllers/logistics_channels_controller.rb` 的 `channel_params` permit 加 `:label_print_type`：

```ruby
  def channel_params
    params.require(:logistics_channel).permit(
      :name, :product_id, :product_shortname, :shopify_carrier_name, :tracking_url_template, :label_print_type
    )
  end
```

`app/views/logistics_channels/_form.html.erb`，在 `tracking_url_template` 欄位 `<div>` 之後、submit 之前加入（用 select 常用值，允許其他）：

```erb
      <div>
        <label class="block text-sm font-medium text-gray-700" for="logistics_channel_label_print_type"><%= t("logistics_channels.label_print_type") %></label>
        <%= f.select :label_print_type, [ "lab10_10", "A4" ], {}, class: "mt-1 w-full max-w-md border border-gray-300 rounded px-3 py-2 text-sm" %>
      </div>
```

- [ ] **Step 4: Generalize the index bulk form for pending_label**

`app/views/packages/index.html.erb`：把 2C 寫死 `pending_process` 的批量表單一般化，讓 `pending_label` 也有批量（但表單 url / 按鈕 / target 不同）。把現有 bulk 區塊改為：

```erb
  <% bulk = %w[pending_process pending_label].include?(@state) %>
  <% bulk_url = @state == "pending_label" ? labels_packages_path : apply_tracking_bulk_packages_path %>
  <% bulk_label = @state == "pending_label" ? t("packages.label.bulk_button") : t("packages.apply.bulk_button") %>
  <% bulk_html = @state == "pending_label" ? { id: "packages-bulk-form", target: "_blank" } : { id: "packages-bulk-form" } %>
  <%= form_with url: bulk_url, method: :post,
        data: (bulk ? { controller: "package-bulk" } : {}), html: bulk_html do %>
    <% if bulk %>
      <div data-package-bulk-target="bar" class="hidden mb-3 flex items-center gap-3 px-4 py-2 bg-indigo-50 border border-indigo-200 rounded">
        <span class="text-sm text-indigo-800"><%= bulk_label %> · <span data-package-bulk-target="count">0</span></span>
        <%= submit_tag bulk_label, class: "px-3 py-1.5 text-sm bg-indigo-600 text-white rounded hover:bg-indigo-700 cursor-pointer" %>
      </div>
    <% end %>
    <%# ...rest of the table unchanged (thead toggle-all when bulk, colspan bulk?9:8, _package_row bulk:)... %>
```

> 表格其餘部分（thead 的 toggle-all、`colspan bulk ? 9 : 8`、`render "packages/package_row", package:, bulk:`）**維持 2C 現狀不變**——它們已用 `bulk` 變數，一般化後自動同時支援 pending_label。`_package_row` 的 checkbox（`package_ids[]` + `data-package-bulk-target`）已在 2C 加好，不動。

- [ ] **Step 5: Sanity checks**

Run:
```
PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rails runner "%w[en zh-TW zh-CN].each { |l| I18n.locale=l; %w[packages.label.button packages.label.bulk_button packages.label.errors.mixed_type packages.label.errors.failed logistics_channels.label_print_type].each { |k| raise \"missing #{k} in #{l}\" unless I18n.exists?(k) } }; puts 'i18n ok'"
PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/packages_spec.rb spec/requests/logistics_channels_spec.rb
PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rubocop
```
Expected: 「i18n ok」；request specs 綠（含既有 logistics_channels）；RuboCop 0。

- [ ] **Step 6: Commit**

```bash
git add app/views/packages app/views/logistics_channels app/controllers/logistics_channels_controller.rb config/locales
git commit -m "feat(packing): label print button, bulk print form, channel print-type field + i18n"
```

---

### Task 6: System specs + 渠道表單 request spec

**Files:**
- Modify: `spec/system/packages_spec.rb`
- Modify: `spec/requests/logistics_channels_spec.rb`

**Interfaces:**
- Consumes: Task 1–5 全部。

- [ ] **Step 1: Channel-form request spec (label_print_type editable)**

在 `spec/requests/logistics_channels_spec.rb` 新增。該檔既有慣例：`let(:owner)`/`let(:company)`/`let(:account) { create(:logistics_account, company: company, url1_base: ...) }`、`before { sign_in owner }`，且 update 測試用**部分參數**（例如 `patch logistics_channel_path(id: channel.id), params: { logistics_channel: { name: "New name" } }`）。沿用之，做部分更新只帶 `label_print_type`：

```ruby
it "persists label_print_type on update" do
  channel = create(:logistics_channel, logistics_account: account, label_print_type: "lab10_10")
  patch logistics_channel_path(id: channel.id), params: { logistics_channel: { label_print_type: "A4" } }
  expect(channel.reload.label_print_type).to eq("A4")
end
```

> 放進該檔既有的 update `describe`/`context` 內（與 line ~70 的 "New name" 部分更新測試相鄰），才能共用其 `account`/`sign_in owner` 前置。

- [ ] **Step 2: System specs**

在 `spec/system/packages_spec.rb` 新增（沿用 `sign_in_as(user)` 與既有 `let`；WebMock 在 system 亦生效）：

```ruby
describe "印面单" do
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089", customer_id: "1", customer_userid: "2") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1", label_print_type: "lab10_10") }

  def label_pkg(number: 900)
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#L#{number}")
    create(:package, shopify_store: store, order: order, number: number, aasm_state: "pending_label", logistics_channel: channel, raydo_order_id: "R#{number}")
  end

  it "shows the 打印面单 button on a pending_label package modal" do
    pkg = label_pkg
    visit packages_path(state: "pending_label")
    click_link pkg.package_code
    expect(page).to have_link(I18n.t("packages.label.button"), href: label_package_path(id: pkg.id))
  end

  it "shows the bulk print bar when a pending_label row is checked" do
    label_pkg
    visit packages_path(state: "pending_label")
    first("input[name='package_ids[]']").check
    expect(page).to have_button(I18n.t("packages.label.bulk_button"))
  end
end
```

> 註：PDF 內容/新分頁下載無法在 system spec 穩定斷言（Selenium 不便驗 PDF 下載）；面單正確性由 Task 2/3 service spec 與 Task 4 request spec（`application/pdf` + `%PDF`）覆蓋。此處只驗按鈕/批量列存在（Turbo/Stimulus 契約）。若本機 chromedriver 超前 Chrome，依 [[local-system-test-chromedriver]] 把 `/tmp/chromedriver-linux64` 前置 PATH。

- [ ] **Step 3: Run**

Run: `PATH=/tmp/chromedriver-linux64:/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/logistics_channels_spec.rb spec/system/packages_spec.rb -e "印面单"`
Expected: PASS。

- [ ] **Step 4: Commit**

```bash
git add spec/system/packages_spec.rb spec/requests/logistics_channels_spec.rb
git commit -m "test(packing): system + channel-form specs for label printing"
```

---

### Task 7: 全套驗證 + PR

**Files:** 無新增。

- [ ] **Step 1: Full suite**

Run: `PATH=/tmp/chromedriver-linux64:/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec`
Expected: 全綠、coverage ≥ 95%。系統測試若有既知 timing-flaky（[[flaky-system-tests]]），重跑失敗例確認 flaky vs real；2D 程式碼的真實失敗須停下修正。

- [ ] **Step 2: Lint + security**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rubocop && bin/brakeman --no-pager`
Expected: RuboCop 0；Brakeman 無新警告（留意 `label`/`labels` 的 `send_data`、`params[:package_ids]` 僅用於 `where(id:)` 查詢）。

- [ ] **Step 3: Push + PR**

```bash
git push -u origin feature/order-packing-phase2d-label
```
本分支疊在 2C 上。**PR base 選擇**：若 2C（PR #223）已合併 staging，`gh pr create --base staging`；若尚未，暫以 `--base feature/order-packing-phase2c`（stacked PR），待 2C 合併後改指向 staging。PR 內文列範圍（只印面單、可重印）、Q1–Q5 決策、URL2 PDF proxy、批量同類型、以及依賴 2C。結尾加：
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`

---

## Self-Review（對照 spec）

- **Spec 覆蓋**：channel label_print_type + package_shipping?→T1；Raydo#label_pdf(URL2/PDF/錯誤)→T2；PackageLabelPrinter(驗證各分支/同類型合併)→T3；controller label/labels+routes+權限/404/inline PDF→T4；UI 印面单鈕/批量表單/渠道欄位/i18n→T5；system+channel-form→T6；驗證/PR→T7。全部有對應任務。
- **Placeholder 掃描**：無 TBD/TODO；每步附完整程式碼與指令。
- **型別一致**：`Raydo#label_pdf(order_ids, print_type)→String`、`PackageLabelPrinter.new(packages).call→Result(success?/pdf/filename/error)`、error symbols(:empty/:invalid_state/:no_order/:no_channel/:mixed_type/:url2_missing)、route helpers `label_package_path`/`labels_packages_path`、`Membership#package_shipping?`、`LogisticsChannel#label_print_type`、`package-bulk` Stimulus identifier（沿用 2C）在各 task 一致。
- **執行時需對齊處**（已就地標註）：`package_shipping?` 為本階段新增（controller 依賴，T1 先建）；i18n `packages.label.*` 在 T5 補，T4 的 `t(..., default:)` 不會炸；channel-form request spec 對齊該檔既有 update 寫法；index bulk 一般化沿用 2C 的 `bulk` 變數與 `package-bulk` identifier；views 非 strict-locals，`local_assigns[:bulk]` 選填安全。
