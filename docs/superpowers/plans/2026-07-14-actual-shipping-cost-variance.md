# 實際運費與差異比較報表 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓貨代帳單的 per-parcel 實際運費能透過 Excel 匯入與 API 寫進系統，rollup 到 `orders.actual_shipping_cost`，並提供訂單維度的「實際 vs 預估」差異報表與 Dashboard 物流 Section。

**Architecture:** 新增 `parcels` 表（唯一鍵 `[shopify_store_id, identifier]`，identifier 為店小秘「订单编号」）。單一 `ParcelUpserter` service 同時服務 Excel 匯入與 AI agent API，保證兩條寫入路徑規則一致。Parcel 存檔/刪除後 rollup 到既有的 `orders.actual_shipping_cost` 欄位 —— 該欄位的所有讀取端（`Order#effective_shipping_cost`、`net_profit_per_order`、Dashboard 的 `COALESCE`）早已寫成優先採用實際值，因此無需修改。

**Tech Stack:** Rails 8.1、PostgreSQL（UUID 主鍵）、RSpec + FactoryBot、Hotwire（Turbo Stream inline edit）、Tailwind、Solid Cache（匯入預覽暫存）、新增 gem `roo`（讀 xlsx）。

**設計文件：** `docs/superpowers/specs/2026-07-14-actual-shipping-cost-variance-design.md`

## Global Constraints

- **分支**：`feature/actual-shipping-cost-variance`（已自 `origin/staging` 建立）。**絕不直接 commit 到 `main` 或 `staging`。**
- **所有表的主鍵必須是 UUID**（`id: :uuid`）。
- **測試不得使用 mock**，必須命中真實資料庫。RSpec + FactoryBot，禁用 fixtures。
- **覆蓋率須維持 95%+**。每個 task 都必須含 model / request / system spec（依該 task 性質）。
- **RuboCop Omakase**：每次 commit 前跑 `bin/rubocop`，有 offense 先修。
- **i18n**：所有使用者可見文字必須經 `t()`，且**三個語系檔都要加**：`config/locales/en.yml`、`zh-CN.yml`、`zh-TW.yml`。
- **金額運算一律用 BigDecimal**，不得用 Float。
- **幣別換算方向**：`cost_amount = cost_cny ÷ cost_fx_rate`（`cost_fx_rate` 語意為「1 個店鋪幣別 = 多少 CNY」）。
- **權限**：檢視走 `parcels` permission key；匯入 / 編輯 / 刪除 / API key 產生一律 **owner-only**。

---

## File Structure

| 檔案 | 職責 |
|---|---|
| `db/migrate/*_create_parcels.rb` | parcels 表 |
| `db/migrate/*_add_agent_api_key_to_companies.rb` | company API key |
| `app/models/parcel.rb` | model、驗證、rollup callback |
| `app/models/order.rb`（改） | `has_many :parcels`、`refresh_actual_shipping_cost!`、variance 方法 |
| `app/models/company.rb`（改） | `agent_api_key` 加密與產生 |
| `app/models/membership.rb`（改） | `AVAILABLE_PERMISSIONS` 加 `parcels` |
| `app/services/parcel_bill_parser.rb` | 純解析 xlsx → rows（不碰 DB） |
| `app/services/parcel_upserter.rb` | 單筆 upsert（Excel 與 API 共用） |
| `app/controllers/parcels_controller.rb` | Index（差異報表）、匯入三步、inline edit |
| `app/controllers/api/company_base_controller.rb` | company API key 認證 |
| `app/controllers/api/v1/parcels_controller.rb` | Parcel CRUD API |
| `app/controllers/api/v1/orders_controller.rb` | `GET /orders/:name/shipping` |
| `app/views/parcels/` | index、import、preview、inline edit turbo_stream |
| `app/views/dashboard/_shipping_section.html.erb` | 物流 Section |
| `app/services/dashboard_metrics_service.rb`（改） | variance / multi-parcel 指標 |
| `spec/support/xlsx_builder.rb` | 用 caxlsx 產生測試用 xlsx（避免二進位 fixture） |

---

### Task 1: Parcel model、migration、rollup

**Files:**
- Create: `db/migrate/20260714120001_create_parcels.rb`
- Create: `app/models/parcel.rb`
- Create: `spec/factories/parcels.rb`
- Create: `spec/models/parcel_spec.rb`
- Modify: `app/models/order.rb`
- Modify: `spec/models/order_spec.rb`

**Interfaces:**
- Produces: `Parcel`（`belongs_to :shopify_store`、`belongs_to :order, optional: true`）；`Order#parcels`；`Order#refresh_actual_shipping_cost!`；`Order#shipping_variance`；`Order#shipping_variance_pct`；`Order#parcel_count`

- [ ] **Step 1: 寫失敗的 model spec**

`spec/models/parcel_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe Parcel, type: :model do
  let(:user)  { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let(:order) { create(:order, customer: customer, shopify_store: store, estimated_shipping_cost: 10) }

  describe "rollup to orders.actual_shipping_cost" do
    it "sums parcel cost_amount into the order after create" do
      create(:parcel, shopify_store: store, order: order, cost_amount: 12.34)
      create(:parcel, shopify_store: store, order: order, cost_amount: 5.66)

      expect(order.reload.actual_shipping_cost).to eq(18.00)
    end

    it "recalculates after update" do
      parcel = create(:parcel, shopify_store: store, order: order, cost_amount: 12.34)
      parcel.update!(cost_amount: 20)

      expect(order.reload.actual_shipping_cost).to eq(20)
    end

    it "resets to nil (not zero) when the last parcel is destroyed" do
      parcel = create(:parcel, shopify_store: store, order: order, cost_amount: 12.34)
      parcel.destroy!

      expect(order.reload.actual_shipping_cost).to be_nil
    end

    it "recalculates BOTH orders when a parcel moves between them" do
      other = create(:order, customer: customer, shopify_store: store)
      parcel = create(:parcel, shopify_store: store, order: order, cost_amount: 9)
      expect(order.reload.actual_shipping_cost).to eq(9)

      parcel.update!(order: other)

      expect(order.reload.actual_shipping_cost).to be_nil
      expect(other.reload.actual_shipping_cost).to eq(9)
    end

    it "recalculates the order when an unmatched parcel is assigned to it" do
      parcel = create(:parcel, shopify_store: store, order: nil, cost_amount: 7)
      parcel.update!(order: order)

      expect(order.reload.actual_shipping_cost).to eq(7)
    end
  end

  describe "validations" do
    it "requires identifier to be unique per store" do
      create(:parcel, shopify_store: store, identifier: "XMBDE2012381")
      dup = build(:parcel, shopify_store: store, identifier: "XMBDE2012381")

      expect(dup).not_to be_valid
      expect(dup.errors[:identifier]).to be_present
    end

    it "allows the same identifier in a different store" do
      other_store = create(:shopify_store, user: user, company: user.companies.first)
      create(:parcel, shopify_store: store, identifier: "XMBDE2012381")

      expect(build(:parcel, shopify_store: other_store, identifier: "XMBDE2012381")).to be_valid
    end

    it "requires identifier" do
      expect(build(:parcel, shopify_store: store, identifier: nil)).not_to be_valid
    end
  end
end
```

在 `spec/models/order_spec.rb` 追加：

```ruby
  describe "shipping variance" do
    let(:user)  { create(:user) }
    let(:store) { create(:shopify_store, user: user, company: user.companies.first) }
    let(:customer) { create(:customer, shopify_store: store) }

    it "returns actual minus estimated" do
      order = create(:order, customer: customer, shopify_store: store, estimated_shipping_cost: 10)
      create(:parcel, shopify_store: store, order: order, cost_amount: 15.5)

      expect(order.reload.shipping_variance).to eq(5.5)
      expect(order.shipping_variance_pct).to eq(55.0)
      expect(order.parcel_count).to eq(1)
    end

    it "is nil when either side is missing" do
      order = create(:order, customer: customer, shopify_store: store, estimated_shipping_cost: nil)
      create(:parcel, shopify_store: store, order: order, cost_amount: 15.5)

      expect(order.reload.shipping_variance).to be_nil
      expect(order.shipping_variance_pct).to be_nil
    end

    it "returns nil variance_pct when estimated is zero" do
      order = create(:order, customer: customer, shopify_store: store, estimated_shipping_cost: 0)
      create(:parcel, shopify_store: store, order: order, cost_amount: 15.5)

      expect(order.reload.shipping_variance_pct).to be_nil
    end
  end
```

- [ ] **Step 2: 執行測試，確認失敗**

Run: `bundle exec rspec spec/models/parcel_spec.rb`
Expected: FAIL — `uninitialized constant Parcel`

- [ ] **Step 3: 建立 migration**

`db/migrate/20260714120001_create_parcels.rb`：

```ruby
class CreateParcels < ActiveRecord::Migration[8.1]
  def change
    create_table :parcels, id: :uuid do |t|
      t.references :shopify_store, type: :uuid, null: false, foreign_key: true
      t.references :order,         type: :uuid, null: true,  foreign_key: true

      t.string   :identifier, null: false
      t.string   :internal_no
      t.string   :tracking_number
      t.datetime :shipped_at
      t.string   :service_channel
      t.string   :zone
      t.string   :country
      t.integer  :actual_weight_g
      t.integer  :billed_weight_g

      t.decimal :cost_cny,             precision: 10, scale: 2
      t.decimal :freight_cny,          precision: 10, scale: 2
      t.decimal :registration_fee_cny, precision: 10, scale: 2
      t.decimal :tax_cny,              precision: 10, scale: 2
      t.decimal :remote_area_fee_cny,  precision: 10, scale: 2
      t.decimal :operation_fee_cny,    precision: 10, scale: 2

      t.decimal :fx_rate_snapshot, precision: 10, scale: 4
      t.decimal :cost_amount,      precision: 10, scale: 2

      t.timestamps
    end

    add_index :parcels, [ :shopify_store_id, :identifier ], unique: true
    add_index :parcels, :tracking_number
  end
end
```

（`t.references` 已自動建立 `shopify_store_id` 與 `order_id` 的索引，不需重複加。）

Run: `bin/rails db:migrate && bin/rails db:test:prepare`

- [ ] **Step 4: 建立 Parcel model**

`app/models/parcel.rb`：

```ruby
class Parcel < ApplicationRecord
  belongs_to :shopify_store
  belongs_to :order, optional: true

  validates :identifier, presence: true,
                         uniqueness: { scope: :shopify_store_id }

  scope :unmatched, -> { where(order_id: nil) }

  after_save    :refresh_order_rollups
  after_destroy :refresh_order_rollups

  private

  # A parcel can move between orders (e.g. an unmatched parcel gets assigned).
  # Both the old and the new order must be recalculated, otherwise the old one
  # keeps a stale actual_shipping_cost that no longer has any parcels backing it.
  def refresh_order_rollups
    ids = [ order_id, order_id_previously_was ].compact.uniq
    Order.where(id: ids).find_each(&:refresh_actual_shipping_cost!)
  end
end
```

- [ ] **Step 5: 修改 Order model**

在 `app/models/order.rb` 的 `has_many :tickets, dependent: :nullify` 之後加入關聯：

```ruby
  has_many :parcels, dependent: :nullify
```

並在 `shipping_is_actual?` 之後（class 結尾 `end` 之前）加入：

```ruby
  # actual_shipping_cost is a denormalized rollup of the order's parcels. It must
  # be nil — not 0 — when there are no parcels, otherwise effective_shipping_cost
  # would treat 0 as "we know the actual cost" and stop falling back to the estimate.
  def refresh_actual_shipping_cost!
    total = parcels.exists? ? parcels.sum(:cost_amount) : nil
    update_column(:actual_shipping_cost, total)
  end

  def parcel_count
    parcels.count
  end

  def shipping_variance
    return nil unless actual_shipping_cost && estimated_shipping_cost
    actual_shipping_cost - estimated_shipping_cost
  end

  def shipping_variance_pct
    return nil unless estimated_shipping_cost&.positive?
    return nil unless shipping_variance
    (shipping_variance / estimated_shipping_cost * 100).round(2)
  end
```

- [ ] **Step 6: 建立 factory**

`spec/factories/parcels.rb`：

```ruby
FactoryBot.define do
  factory :parcel do
    shopify_store
    order { nil }
    sequence(:identifier) { |n| "XMBDE#{2012380 + n}" }
    sequence(:internal_no) { |n| "DOR#{201415420 + n}CN" }
    sequence(:tracking_number) { |n| "YWSFO#{10040079220 + n}" }
    shipped_at { 3.days.ago }
    service_channel { "美国标准（A带电）" }
    country { "美国" }
    actual_weight_g { 2423 }
    billed_weight_g { 2421 }
    cost_cny { 239.73 }
    freight_cny { 222.73 }
    registration_fee_cny { 15 }
    tax_cny { 0 }
    remote_area_fee_cny { 0 }
    operation_fee_cny { 2 }
    fx_rate_snapshot { 7.2 }
    cost_amount { 33.30 }
  end
end
```

- [ ] **Step 7: 執行測試，確認通過**

Run: `bundle exec rspec spec/models/parcel_spec.rb spec/models/order_spec.rb`
Expected: PASS（全部綠燈）

- [ ] **Step 8: RuboCop 與 commit**

```bash
bin/rubocop -a app/models/parcel.rb app/models/order.rb spec/factories/parcels.rb spec/models/parcel_spec.rb
git add db/migrate db/schema.rb app/models/parcel.rb app/models/order.rb spec/factories/parcels.rb spec/models/parcel_spec.rb spec/models/order_spec.rb
git commit -m "feat(shipping): add Parcel model with rollup to orders.actual_shipping_cost"
```

---

### Task 2: ParcelBillParser（讀 xlsx）

**Files:**
- Modify: `Gemfile`
- Create: `app/services/parcel_bill_parser.rb`
- Create: `spec/support/xlsx_builder.rb`
- Create: `spec/services/parcel_bill_parser_spec.rb`

**Interfaces:**
- Consumes: 無（純解析，不碰 DB）
- Produces: `ParcelBillParser.new(path).call` → `{ rows: [Hash], errors: [String] }`。每個 row hash 的 key 為：`:identifier, :order_name, :internal_no, :tracking_number, :shipped_at, :service_channel, :zone, :country, :actual_weight_g, :billed_weight_g, :cost_cny, :freight_cny, :registration_fee_cny, :tax_cny, :remote_area_fee_cny, :operation_fee_cny`

- [ ] **Step 1: 加入 roo gem**

在 `Gemfile` 中 `gem "caxlsx", "~> 4.1"` 那一行下方加入：

```ruby
# Read .xlsx carrier bills (caxlsx only writes; it cannot read)
gem "roo", "~> 2.10"
```

Run: `bundle install`

- [ ] **Step 2: 建立測試用 xlsx builder**

`spec/support/xlsx_builder.rb`（用專案已有的 `caxlsx` **寫出** xlsx，讓 `roo` **讀進來** —— 避免把二進位 fixture 檔進版控）：

```ruby
require "axlsx"

# Builds a carrier-bill .xlsx in a temp file, mirroring the real Dianxiaomi
# export layout (see the 2026-07-14 design doc §2). Returns the file path.
module XlsxBuilder
  HEADERS = [
    "序号", "发货时间", "订单编号", "交易编号", "内部单号", "货运单号",
    "物流渠道", "分区", "国家(中)", "重量", "店铺名", "订单状态", "店长", "平台",
    "计费重（G)", "运费单价/g", "运费总价", "挂号费", "税金", "偏远费",
    "总运费", "操作费", "加单总运费（RMB)"
  ].freeze

  # A representative row. Overrides are merged by header name.
  def self.row(seq:, identifier:, order_name:, cost: 239.732, **over)
    defaults = {
      "序号" => seq,
      "发货时间" => Time.utc(2026, 6, 1, 21, 48, 26),
      "订单编号" => identifier,
      "交易编号" => order_name,
      "内部单号" => "DOR0201415428CN",
      "货运单号" => "SPXORH011122606010001237",
      "物流渠道" => "美国标准（A带电）",
      "分区" => nil,
      "国家(中)" => "美国",
      "重量" => 2423,
      "店铺名" => "CSFD-STORE1",
      "订单状态" => "已发货",
      "店长" => "CSFD",
      "平台" => "Other",
      "计费重（G)" => 2421,
      "运费单价/g" => 0.092,
      "运费总价" => 222.732,
      "挂号费" => 15,
      "税金" => 0,
      "偏远费" => 0,
      "总运费" => 237.732,
      "操作费" => 2,
      "加单总运费（RMB)" => cost
    }
    defaults.merge(over.transform_keys(&:to_s))
  end

  # rows: array of hashes from .row; totals: array of numbers appended as
  # header-less total rows (序号 blank) to mimic the real file's SUM footer.
  def self.build(rows:, totals: [ 58_578.977 ])
    path = Rails.root.join("tmp", "parcel_bill_#{SecureRandom.hex(6)}.xlsx").to_s
    Axlsx::Package.new do |p|
      p.workbook.add_worksheet(name: "6月") do |sheet|
        sheet.add_row HEADERS
        rows.each { |r| sheet.add_row HEADERS.map { |h| r[h] } }
        totals.each do |t|
          blanks = Array.new(HEADERS.size - 1)
          sheet.add_row(blanks + [ t ])
        end
      end
      p.serialize(path)
    end
    path
  end
end
```

在 `spec/rails_helper.rb` 的 `RSpec.configure` 區塊**之前**，確認 support 檔有被載入。若 `spec/rails_helper.rb` 尚無 support 載入行，加入：

```ruby
Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |f| require f }
```

（若已存在同等的載入行，跳過此步。）

- [ ] **Step 3: 寫失敗的 parser spec**

`spec/services/parcel_bill_parser_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe ParcelBillParser do
  def build_file(rows:, totals: [ 58_578.977 ])
    XlsxBuilder.build(rows: rows, totals: totals)
  end

  it "maps the Chinese headers onto parcel attributes" do
    path = build_file(rows: [
      XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.732)
    ])

    result = described_class.new(path).call

    expect(result[:errors]).to be_empty
    expect(result[:rows].size).to eq(1)

    row = result[:rows].first
    expect(row[:identifier]).to eq("XMBDE2012381")
    expect(row[:order_name]).to eq("PKS#3037")
    expect(row[:internal_no]).to eq("DOR0201415428CN")
    expect(row[:tracking_number]).to eq("SPXORH011122606010001237")
    expect(row[:service_channel]).to eq("美国标准（A带电）")
    expect(row[:country]).to eq("美国")
    expect(row[:actual_weight_g]).to eq(2423)
    expect(row[:billed_weight_g]).to eq(2421)
    expect(row[:cost_cny]).to eq(BigDecimal("239.73"))
    expect(row[:registration_fee_cny]).to eq(BigDecimal("15"))
    expect(row[:operation_fee_cny]).to eq(BigDecimal("2"))
    expect(row[:shipped_at]).to be_present
  end

  it "excludes the footer total rows (they have no 序号)" do
    path = build_file(
      rows: [
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037"),
        XlsxBuilder.row(seq: 2, identifier: "XMBDE2012382", order_name: "PKS#3038")
      ],
      totals: [ 58_578.977, 239_735.764 ]
    )

    result = described_class.new(path).call

    expect(result[:rows].size).to eq(2)
    expect(result[:rows].map { |r| r[:identifier] })
      .to contain_exactly("XMBDE2012381", "XMBDE2012382")
  end

  it "reports a row whose identifier is blank" do
    path = build_file(rows: [
      XlsxBuilder.row(seq: 1, identifier: nil, order_name: "PKS#3037")
    ])

    result = described_class.new(path).call

    expect(result[:rows]).to be_empty
    expect(result[:errors].first).to include("订单编号")
  end

  it "reports a row whose cost is blank" do
    path = build_file(rows: [
      XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: nil)
    ])

    result = described_class.new(path).call

    expect(result[:rows]).to be_empty
    expect(result[:errors].first).to include("加单总运费")
  end

  it "reports a missing required header instead of silently mis-mapping" do
    path = Rails.root.join("tmp", "bad_#{SecureRandom.hex(4)}.xlsx").to_s
    Axlsx::Package.new do |p|
      p.workbook.add_worksheet(name: "x") { |s| s.add_row [ "序号", "订单编号" ] }
      p.serialize(path)
    end

    result = described_class.new(path).call

    expect(result[:rows]).to be_empty
    expect(result[:errors].first).to include("加单总运费（RMB)")
  end
end
```

- [ ] **Step 4: 執行測試，確認失敗**

Run: `bundle exec rspec spec/services/parcel_bill_parser_spec.rb`
Expected: FAIL — `uninitialized constant ParcelBillParser`

- [ ] **Step 5: 實作 parser**

`app/services/parcel_bill_parser.rb`：

```ruby
require "roo"

# Parses a Dianxiaomi carrier-bill .xlsx into plain row hashes. Pure parsing —
# it never touches the database. Rows without a 序号 are skipped, which is how
# the file's footer SUM rows get excluded (see design doc §2).
class ParcelBillParser
  # Header text → row key. Exact strings as they appear in the export, including
  # the full-width parenthesis in 计费重（G) and 加单总运费（RMB).
  COLUMN_MAP = {
    "订单编号" => :identifier,
    "交易编号" => :order_name,
    "内部单号" => :internal_no,
    "货运单号" => :tracking_number,
    "发货时间" => :shipped_at,
    "物流渠道" => :service_channel,
    "分区" => :zone,
    "国家(中)" => :country,
    "重量" => :actual_weight_g,
    "计费重（G)" => :billed_weight_g,
    "运费总价" => :freight_cny,
    "挂号费" => :registration_fee_cny,
    "税金" => :tax_cny,
    "偏远费" => :remote_area_fee_cny,
    "操作费" => :operation_fee_cny,
    "加单总运费（RMB)" => :cost_cny
  }.freeze

  SEQUENCE_HEADER = "序号".freeze
  REQUIRED_HEADERS = [ SEQUENCE_HEADER, "订单编号", "加单总运费（RMB)" ].freeze

  MONEY_KEYS   = %i[cost_cny freight_cny registration_fee_cny tax_cny remote_area_fee_cny operation_fee_cny].freeze
  INTEGER_KEYS = %i[actual_weight_g billed_weight_g].freeze

  def initialize(path)
    @path = path.to_s
  end

  def call
    sheet = Roo::Excelx.new(@path).sheet(0)
    header_row = sheet.row(1).map { |c| c.to_s.strip }

    missing = REQUIRED_HEADERS.reject { |h| header_row.include?(h) }
    return { rows: [], errors: [ "缺少必要欄位：#{missing.join('、')}" ] } if missing.any?

    index = header_row.each_with_index.to_h
    rows = []
    errors = []

    (2..sheet.last_row).each do |n|
      raw = sheet.row(n)
      # Footer total rows carry a value only in the last column and have no 序号.
      next if raw[index[SEQUENCE_HEADER]].blank?

      attrs = extract(raw, index)
      row_errors = validate(attrs, n)
      if row_errors.any?
        errors.concat(row_errors)
      else
        rows << attrs
      end
    end

    { rows: rows, errors: errors }
  rescue Roo::Error, Zip::Error => e
    { rows: [], errors: [ "無法讀取檔案：#{e.message}" ] }
  end

  private

  def extract(raw, index)
    COLUMN_MAP.each_with_object({}) do |(header, key), attrs|
      pos = index[header]
      value = pos ? raw[pos] : nil
      attrs[key] = cast(key, value)
    end
  end

  def cast(key, value)
    return nil if value.blank? && value != 0

    case key
    when :shipped_at   then value.is_a?(String) ? Time.zone.parse(value) : value
    when *MONEY_KEYS   then BigDecimal(value.to_s).round(2)
    when *INTEGER_KEYS then value.to_i
    else value.to_s.strip.presence
    end
  rescue ArgumentError, TypeError
    nil
  end

  def validate(attrs, line)
    errors = []
    errors << "第 #{line} 列：订单编号 為空" if attrs[:identifier].blank?
    errors << "第 #{line} 列：加单总运费（RMB) 為空或非數字" if attrs[:cost_cny].blank?
    errors
  end
end
```

- [ ] **Step 6: 執行測試，確認通過**

Run: `bundle exec rspec spec/services/parcel_bill_parser_spec.rb`
Expected: PASS（6 examples）

- [ ] **Step 7: 用真實帳單驗證（一次性 sanity check，不進版控）**

```bash
bin/rails runner 'r = ParcelBillParser.new("/Users/simon/Downloads/2026.6月SIMON.xlsx").call; puts "rows=#{r[:rows].size} errors=#{r[:errors].size}"; puts "sum=#{r[:rows].sum { |x| x[:cost_cny] }}"'
```

Expected: `rows=482 errors=0`、`sum=58578.98`（±0.01，因逐筆 round(2)）。若 rows 不是 482，代表總計行沒被濾掉或表頭對不上，**必須修到符合為止**。

- [ ] **Step 8: RuboCop 與 commit**

```bash
bin/rubocop -a app/services/parcel_bill_parser.rb spec/services/parcel_bill_parser_spec.rb spec/support/xlsx_builder.rb
git add Gemfile Gemfile.lock app/services/parcel_bill_parser.rb spec/services/parcel_bill_parser_spec.rb spec/support/xlsx_builder.rb spec/rails_helper.rb
git commit -m "feat(shipping): parse Dianxiaomi carrier bill xlsx into parcel rows"
```

---

### Task 3: ParcelUpserter（Excel 與 API 共用的寫入規則）

**Files:**
- Create: `app/services/parcel_upserter.rb`
- Create: `spec/services/parcel_upserter_spec.rb`

**Interfaces:**
- Consumes: Task 1 的 `Parcel`；Task 2 的 row hash 格式
- Produces: `ParcelUpserter.new(store: ShopifyStore, attrs: Hash).call` → `Parcel`（已存檔）。`attrs` 接受 Task 2 的 row key，其中 `:order_name` 會被解析成 `order_id`。`ParcelUpserter::MissingFxRate`（例外類別）

- [ ] **Step 1: 寫失敗的 spec**

`spec/services/parcel_upserter_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe ParcelUpserter do
  let(:user)  { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:order)   { create(:order, customer: customer, shopify_store: store, name: "PKS#3037") }

  def attrs(over = {})
    {
      identifier: "XMBDE2012381",
      order_name: "PKS#3037",
      internal_no: "DOR0201415428CN",
      tracking_number: "SPXORH011122606010001237",
      shipped_at: Time.utc(2026, 6, 1, 21, 48, 26),
      service_channel: "美国标准（A带电）",
      zone: nil,
      country: "美国",
      actual_weight_g: 2423,
      billed_weight_g: 2421,
      cost_cny: BigDecimal("239.73"),
      freight_cny: BigDecimal("222.73"),
      registration_fee_cny: BigDecimal("15"),
      tax_cny: BigDecimal("0"),
      remote_area_fee_cny: BigDecimal("0"),
      operation_fee_cny: BigDecimal("2")
    }.merge(over)
  end

  it "creates a parcel, converts CNY to store currency and snapshots the fx rate" do
    parcel = described_class.new(store: store, attrs: attrs).call

    expect(parcel).to be_persisted
    expect(parcel.order).to eq(order)
    expect(parcel.fx_rate_snapshot).to eq(7.2)
    expect(parcel.cost_amount).to eq(BigDecimal("33.30"))   # 239.73 / 7.2 = 33.2958…
    expect(order.reload.actual_shipping_cost).to eq(BigDecimal("33.30"))
  end

  it "is idempotent — the same identifier updates instead of duplicating" do
    described_class.new(store: store, attrs: attrs).call
    described_class.new(store: store, attrs: attrs(cost_cny: BigDecimal("100.00"))).call

    expect(Parcel.where(shopify_store: store, identifier: "XMBDE2012381").count).to eq(1)
    expect(Parcel.last.cost_cny).to eq(100)
    expect(order.reload.actual_shipping_cost).to eq(BigDecimal("13.89"))  # 100 / 7.2
  end

  it "leaves order_id nil when the order name matches nothing" do
    parcel = described_class.new(store: store, attrs: attrs(order_name: "PKS#9999")).call

    expect(parcel.order_id).to be_nil
    expect(parcel.cost_amount).to eq(BigDecimal("33.30"))  # still costed — money is never lost
  end

  it "matches the order only within the given store" do
    other_store = create(:shopify_store, user: user, company: user.companies.first, cost_fx_rate: 7.2)
    parcel = described_class.new(store: other_store, attrs: attrs).call

    expect(parcel.order_id).to be_nil
  end

  it "raises MissingFxRate when the store has no cost_fx_rate" do
    store.update!(cost_fx_rate: nil)

    expect { described_class.new(store: store, attrs: attrs).call }
      .to raise_error(ParcelUpserter::MissingFxRate)
  end

  it "handles a resend parcel (R1 suffix) as a separate parcel on the same order" do
    described_class.new(store: store, attrs: attrs(identifier: "XMBDE2012399")).call
    described_class.new(store: store, attrs: attrs(identifier: "XMBDE2012399R1", cost_cny: BigDecimal("65.76"))).call

    expect(order.reload.parcels.count).to eq(2)
    expect(order.actual_shipping_cost).to eq(BigDecimal("42.43"))  # 33.30 + 9.13
  end
end
```

- [ ] **Step 2: 執行測試，確認失敗**

Run: `bundle exec rspec spec/services/parcel_upserter_spec.rb`
Expected: FAIL — `uninitialized constant ParcelUpserter`

- [ ] **Step 3: 實作 upserter**

`app/services/parcel_upserter.rb`：

```ruby
# The single write path for parcels. Both the Excel importer and the agent API
# call this, so a parcel created by an AI agent obeys exactly the same rules as
# one imported from a spreadsheet.
class ParcelUpserter
  class MissingFxRate < StandardError; end

  ATTRIBUTES = %i[
    internal_no tracking_number shipped_at service_channel zone country
    actual_weight_g billed_weight_g
    cost_cny freight_cny registration_fee_cny tax_cny remote_area_fee_cny operation_fee_cny
  ].freeze

  def initialize(store:, attrs:)
    @store = store
    @attrs = attrs.symbolize_keys
  end

  def call
    fx = @store.cost_fx_rate
    raise MissingFxRate, "store #{@store.id} has no cost_fx_rate" unless fx&.positive?

    parcel = Parcel.find_or_initialize_by(
      shopify_store_id: @store.id,
      identifier: @attrs.fetch(:identifier)
    )

    parcel.assign_attributes(@attrs.slice(*ATTRIBUTES))
    parcel.order_id         = resolve_order_id
    parcel.fx_rate_snapshot = fx
    parcel.cost_amount      = converted_cost(fx)
    parcel.save!
    parcel
  end

  private

  # Bill "交易编号" (e.g. PKS#3037) is the Shopify order name verbatim — no
  # string munging needed. Scoped to the store so two stores can't cross-match.
  def resolve_order_id
    name = @attrs[:order_name]
    return nil if name.blank?

    Order.where(shopify_store_id: @store.id, name: name.to_s.strip).pick(:id)
  end

  def converted_cost(fx)
    cny = @attrs[:cost_cny]
    return nil if cny.blank?

    (BigDecimal(cny.to_s) / BigDecimal(fx.to_s)).round(2)
  end
end
```

- [ ] **Step 4: 執行測試，確認通過**

Run: `bundle exec rspec spec/services/parcel_upserter_spec.rb`
Expected: PASS（6 examples）

- [ ] **Step 5: RuboCop 與 commit**

```bash
bin/rubocop -a app/services/parcel_upserter.rb spec/services/parcel_upserter_spec.rb
git add app/services/parcel_upserter.rb spec/services/parcel_upserter_spec.rb
git commit -m "feat(shipping): add ParcelUpserter shared by Excel import and agent API"
```

---

### Task 4: Excel 匯入流程（上傳 → 預覽 → 確認）

**Files:**
- Create: `app/controllers/parcels_controller.rb`
- Create: `app/views/parcels/import.html.erb`
- Create: `app/views/parcels/preview.html.erb`
- Modify: `config/routes.rb`
- Modify: `app/models/membership.rb`
- Modify: `config/locales/en.yml`, `zh-CN.yml`, `zh-TW.yml`
- Create: `spec/requests/parcel_imports_spec.rb`

**Interfaces:**
- Consumes: Task 2 `ParcelBillParser`；Task 3 `ParcelUpserter`
- Produces: routes `import_parcels_path`(GET)、`preview_parcels_path`(POST)、`confirm_import_parcels_path`(POST)；`ParcelsController#require_owner!`（Task 5 沿用）

- [ ] **Step 1: 加入權限 key**

`app/models/membership.rb` 的 `AVAILABLE_PERMISSIONS` 改為：

```ruby
  AVAILABLE_PERMISSIONS = %w[
    orders shipments tickets ad_campaigns
    shopify_stores ad_accounts email_accounts
    shipping_reminder_rules parcels
  ].freeze
```

- [ ] **Step 2: 加入路由**

`config/routes.rb`，在 `resources :shopify_stores` 區塊之後、`scope "(:locale)"` 內部加入：

```ruby
    resources :parcels, only: [ :index, :update, :destroy ] do
      collection do
        get  :import
        post :preview
        post :confirm_import
      end
    end
```

- [ ] **Step 3: 寫失敗的 request spec**

`spec/requests/parcel_imports_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe "Parcel imports", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:order)   { create(:order, customer: customer, shopify_store: store, name: "PKS#3037") }

  before { sign_in user }

  def upload(path)
    Rack::Test::UploadedFile.new(path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  def bill(rows)
    XlsxBuilder.build(rows: rows)
  end

  describe "GET /parcels/import" do
    it "renders the upload form for an owner" do
      get import_parcels_path
      expect(response).to have_http_status(:ok)
    end

    it "rejects a non-owner member" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member)
      sign_out user
      sign_in member

      get import_parcels_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "POST /parcels/preview" do
    it "summarises new / overwritten / unmatched without writing anything" do
      create(:parcel, shopify_store: store, order: order, identifier: "XMBDE2012381", cost_amount: 1)

      path = bill([
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037"),
        XlsxBuilder.row(seq: 2, identifier: "XMBDE2012382", order_name: "PKS#3038"),  # unmatched order
        XlsxBuilder.row(seq: 3, identifier: "XMBDE2012383", order_name: "PKS#3037")
      ])

      expect {
        post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }
      }.not_to change(Parcel, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("3")   # parsed count
      expect(assigns_summary[:create_count]).to eq(2)
      expect(assigns_summary[:overwrite_count]).to eq(1)
      expect(assigns_summary[:unmatched_count]).to eq(1)
    end

    it "blocks the import when the store has no cost_fx_rate" do
      store.update!(cost_fx_rate: nil)
      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])

      post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }

      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to be_present
    end

    it "rejects a missing file" do
      post preview_parcels_path, params: { shopify_store_id: store.id }
      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to be_present
    end
  end

  describe "POST /parcels/confirm_import" do
    it "writes the cached rows and rolls up onto the order" do
      path = bill([
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.73)
      ])
      post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }
      token = session[:parcel_import_token]

      expect {
        post confirm_import_parcels_path, params: { token: token }
      }.to change(Parcel, :count).by(1)

      expect(order.reload.actual_shipping_cost).to eq(BigDecimal("33.30"))
      expect(response).to redirect_to(parcels_path)
    end

    it "overwrites an existing parcel rather than duplicating it" do
      create(:parcel, shopify_store: store, order: order, identifier: "XMBDE2012381", cost_cny: 1, cost_amount: 1)

      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.73) ])
      post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }

      expect {
        post confirm_import_parcels_path, params: { token: session[:parcel_import_token] }
      }.not_to change(Parcel, :count)

      expect(Parcel.find_by(identifier: "XMBDE2012381").cost_cny).to eq(239.73)
    end

    it "fails cleanly when the cached preview has expired" do
      post confirm_import_parcels_path, params: { token: "nonexistent" }

      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to be_present
    end
  end

  # The preview summary is rendered into the page; assert on the ivar via a
  # request-spec-safe helper rather than parsing HTML.
  def assigns_summary
    @request_summary ||= controller.instance_variable_get(:@summary)
  end
end
```

- [ ] **Step 4: 執行測試，確認失敗**

Run: `bundle exec rspec spec/requests/parcel_imports_spec.rb`
Expected: FAIL — routing error（`import_parcels_path` 未定義）或 `uninitialized constant ParcelsController`

- [ ] **Step 5: 實作 controller 的匯入部分**

`app/controllers/parcels_controller.rb`（Index 在 Task 5 補上，此處先放匯入三個 action）：

```ruby
class ParcelsController < AdminController
  before_action :require_owner!, only: [ :import, :preview, :confirm_import, :update, :destroy ]

  CACHE_TTL = 30.minutes

  def import
    @stores = visible_shopify_stores.order(:name)
  end

  # Parse + summarise. Writes nothing — the rows are held in Solid Cache until
  # the user confirms. Overwriting money silently is exactly what this guards.
  def preview
    store = visible_shopify_stores.find_by(id: params[:shopify_store_id])
    return redirect_to(import_parcels_path, alert: t("parcels.import.store_required")) unless store
    return redirect_to(import_parcels_path, alert: t("parcels.import.fx_rate_missing", store: store.name)) unless store.cost_fx_rate&.positive?

    file = params[:file]
    return redirect_to(import_parcels_path, alert: t("parcels.import.file_required")) if file.blank?

    result = ParcelBillParser.new(file.tempfile.path).call
    @errors = result[:errors]
    rows = result[:rows]

    if rows.empty?
      return redirect_to(import_parcels_path, alert: t("parcels.import.no_rows", errors: @errors.first(3).join("; ")))
    end

    @store = store
    @summary = summarise(store, rows)

    token = SecureRandom.hex(16)
    Rails.cache.write(cache_key(token), { store_id: store.id, rows: rows }, expires_in: CACHE_TTL)
    session[:parcel_import_token] = token
    @token = token

    render :preview
  end

  def confirm_import
    payload = Rails.cache.read(cache_key(params[:token]))
    return redirect_to(import_parcels_path, alert: t("parcels.import.expired")) if payload.blank?

    store = visible_shopify_stores.find_by(id: payload[:store_id])
    return redirect_to(import_parcels_path, alert: t("parcels.import.store_required")) unless store

    count = 0
    Parcel.transaction do
      payload[:rows].each do |row|
        ParcelUpserter.new(store: store, attrs: row).call
        count += 1
      end
    end

    Rails.cache.delete(cache_key(params[:token]))
    session.delete(:parcel_import_token)

    redirect_to parcels_path, notice: t("parcels.import.done", count: count)
  rescue ParcelUpserter::MissingFxRate
    redirect_to import_parcels_path, alert: t("parcels.import.fx_rate_missing", store: store&.name)
  end

  private

  def require_owner!
    return if current_membership&.owner?

    redirect_to authenticated_root_path, alert: t("companies.no_permission")
  end

  def cache_key(token)
    "parcel_import:#{token}"
  end

  def summarise(store, rows)
    identifiers = rows.map { |r| r[:identifier] }
    existing = Parcel.where(shopify_store_id: store.id, identifier: identifiers).pluck(:identifier).to_set

    order_names = rows.map { |r| r[:order_name] }.compact.uniq
    known_names = Order.where(shopify_store_id: store.id, name: order_names).pluck(:name).to_set

    unmatched = rows.reject { |r| r[:order_name].present? && known_names.include?(r[:order_name]) }
    overwrite = rows.select { |r| existing.include?(r[:identifier]) }

    {
      total: rows.size,
      overwrite_count: overwrite.size,
      create_count: rows.size - overwrite.size,
      unmatched_count: unmatched.size,
      unmatched_rows: unmatched.first(20),
      overwrite_rows: overwrite.first(20),
      total_cny: rows.sum { |r| r[:cost_cny] || 0 },
      total_converted: (rows.sum { |r| r[:cost_cny] || 0 } / store.cost_fx_rate).round(2)
    }
  end
end
```

- [ ] **Step 6: 建立匯入頁 view**

`app/views/parcels/import.html.erb`：

```erb
<div class="max-w-2xl mx-auto py-8">
  <h1 class="text-2xl font-semibold text-gray-900 mb-6"><%= t("parcels.import.title") %></h1>

  <%= form_with url: preview_parcels_path, method: :post, multipart: true,
                class: "bg-white rounded-lg border border-gray-200 p-6 space-y-6" do |f| %>
    <div>
      <label for="shopify_store_id" class="block text-sm font-medium text-gray-700 mb-1">
        <%= t("parcels.import.store") %>
      </label>
      <%= select_tag :shopify_store_id,
            options_from_collection_for_select(@stores, :id, :name),
            class: "w-full rounded-md border-gray-300 text-sm",
            id: "shopify_store_id" %>
      <p class="mt-1 text-xs text-gray-500"><%= t("parcels.import.store_hint") %></p>
    </div>

    <div>
      <label for="file" class="block text-sm font-medium text-gray-700 mb-1">
        <%= t("parcels.import.file") %>
      </label>
      <%= file_field_tag :file, accept: ".xlsx", id: "file",
            class: "w-full text-sm text-gray-700" %>
      <p class="mt-1 text-xs text-gray-500"><%= t("parcels.import.file_hint") %></p>
    </div>

    <%= f.submit t("parcels.import.parse"),
          class: "px-4 py-2 bg-gray-900 text-white text-sm font-medium rounded-md hover:bg-gray-800 cursor-pointer" %>
  <% end %>
</div>
```

`app/views/parcels/preview.html.erb`：

```erb
<div class="max-w-3xl mx-auto py-8">
  <h1 class="text-2xl font-semibold text-gray-900 mb-6"><%= t("parcels.import.preview_title") %></h1>

  <div class="bg-white rounded-lg border border-gray-200 p-6 space-y-4">
    <dl class="grid grid-cols-2 gap-4 text-sm">
      <div><dt class="text-gray-500"><%= t("parcels.import.parsed") %></dt>
           <dd class="font-medium text-gray-900"><%= @summary[:total] %></dd></div>
      <div><dt class="text-gray-500"><%= t("parcels.import.will_create") %></dt>
           <dd class="font-medium text-gray-900"><%= @summary[:create_count] %></dd></div>
      <div><dt class="text-gray-500"><%= t("parcels.import.will_overwrite") %></dt>
           <dd class="font-medium <%= @summary[:overwrite_count].positive? ? "text-amber-600" : "text-gray-900" %>">
             <%= @summary[:overwrite_count] %></dd></div>
      <div><dt class="text-gray-500"><%= t("parcels.import.unmatched") %></dt>
           <dd class="font-medium <%= @summary[:unmatched_count].positive? ? "text-amber-600" : "text-gray-900" %>">
             <%= @summary[:unmatched_count] %></dd></div>
      <div><dt class="text-gray-500"><%= t("parcels.import.total_cny") %></dt>
           <dd class="font-medium text-gray-900">¥<%= number_with_precision(@summary[:total_cny], precision: 2) %></dd></div>
      <div><dt class="text-gray-500"><%= t("parcels.import.total_converted") %></dt>
           <dd class="font-medium text-gray-900">
             <%= number_to_currency(@summary[:total_converted]) %>
             <span class="text-xs text-gray-500">@ <%= @store.cost_fx_rate %></span></dd></div>
    </dl>

    <% if @errors.any? %>
      <div class="rounded-md bg-red-50 border border-red-200 p-3">
        <p class="text-sm font-medium text-red-800"><%= t("parcels.import.row_errors", count: @errors.size) %></p>
        <ul class="mt-1 text-xs text-red-700 list-disc list-inside">
          <% @errors.first(10).each do |e| %><li><%= e %></li><% end %>
        </ul>
      </div>
    <% end %>

    <% if @summary[:unmatched_count].positive? %>
      <div class="rounded-md bg-amber-50 border border-amber-200 p-3">
        <p class="text-sm font-medium text-amber-800"><%= t("parcels.import.unmatched_hint") %></p>
        <ul class="mt-1 text-xs text-amber-700 list-disc list-inside">
          <% @summary[:unmatched_rows].each do |r| %>
            <li><%= r[:identifier] %> — <%= r[:order_name].presence || "—" %></li>
          <% end %>
        </ul>
      </div>
    <% end %>

    <div class="flex gap-3 pt-2">
      <%= button_to t("parcels.import.confirm"), confirm_import_parcels_path,
            method: :post, params: { token: @token },
            class: "px-4 py-2 bg-gray-900 text-white text-sm font-medium rounded-md hover:bg-gray-800" %>
      <%= link_to t("parcels.import.cancel"), import_parcels_path,
            class: "px-4 py-2 border border-gray-300 text-gray-700 text-sm font-medium rounded-md hover:bg-gray-50" %>
    </div>
  </div>
</div>
```

- [ ] **Step 7: 加入 i18n（三個語系檔都要）**

`config/locales/zh-TW.yml`，在頂層加入 `parcels:` 區塊：

```yaml
  parcels:
    import:
      title: "匯入運費帳單"
      preview_title: "確認匯入內容"
      store: "帳單所屬店鋪"
      store_hint: "匯率會採用該店鋪目前的成本匯率。"
      file: "帳單檔案 (.xlsx)"
      file_hint: "店小秘匯出的貨代帳單。底部的合計列會自動略過。"
      parse: "解析檔案"
      parsed: "解析筆數"
      will_create: "將新建"
      will_overwrite: "將覆蓋既有資料"
      unmatched: "未配對到訂單"
      total_cny: "帳單總金額"
      total_converted: "換算後金額"
      unmatched_hint: "以下包裹配不到訂單，仍會匯入並標記為未配對，可稍後手動指派。"
      row_errors: "有 %{count} 列無法解析，將被略過"
      confirm: "確認匯入"
      cancel: "取消"
      done: "已匯入 %{count} 筆包裹"
      expired: "預覽已過期，請重新上傳檔案。"
      file_required: "請選擇檔案。"
      store_required: "請選擇店鋪。"
      fx_rate_missing: "店鋪「%{store}」尚未設定成本匯率，請先到店鋪設定填寫後再匯入。"
      no_rows: "檔案中沒有可匯入的資料列。%{errors}"
```

`config/locales/zh-CN.yml`：

```yaml
  parcels:
    import:
      title: "导入运费账单"
      preview_title: "确认导入内容"
      store: "账单所属店铺"
      store_hint: "汇率会采用该店铺当前的成本汇率。"
      file: "账单文件 (.xlsx)"
      file_hint: "店小秘导出的货代账单。底部的合计行会自动跳过。"
      parse: "解析文件"
      parsed: "解析条数"
      will_create: "将新建"
      will_overwrite: "将覆盖已有数据"
      unmatched: "未匹配到订单"
      total_cny: "账单总金额"
      total_converted: "换算后金额"
      unmatched_hint: "以下包裹匹配不到订单，仍会导入并标记为未匹配，可稍后手动指派。"
      row_errors: "有 %{count} 行无法解析，将被跳过"
      confirm: "确认导入"
      cancel: "取消"
      done: "已导入 %{count} 个包裹"
      expired: "预览已过期，请重新上传文件。"
      file_required: "请选择文件。"
      store_required: "请选择店铺。"
      fx_rate_missing: "店铺「%{store}」尚未设置成本汇率，请先到店铺设置填写后再导入。"
      no_rows: "文件中没有可导入的数据行。%{errors}"
```

`config/locales/en.yml`：

```yaml
  parcels:
    import:
      title: "Import shipping bill"
      preview_title: "Confirm import"
      store: "Store this bill belongs to"
      store_hint: "The store's current cost FX rate will be used."
      file: "Bill file (.xlsx)"
      file_hint: "The carrier bill exported from Dianxiaomi. Footer total rows are skipped automatically."
      parse: "Parse file"
      parsed: "Rows parsed"
      will_create: "Will create"
      will_overwrite: "Will overwrite existing"
      unmatched: "Unmatched to an order"
      total_cny: "Bill total"
      total_converted: "Converted total"
      unmatched_hint: "These parcels match no order. They will still be imported and flagged as unmatched — you can assign them later."
      row_errors: "%{count} rows could not be parsed and will be skipped"
      confirm: "Confirm import"
      cancel: "Cancel"
      done: "Imported %{count} parcels"
      expired: "The preview expired. Please upload the file again."
      file_required: "Please choose a file."
      store_required: "Please choose a store."
      fx_rate_missing: "Store \"%{store}\" has no cost FX rate set. Set it in the store settings before importing."
      no_rows: "The file has no importable data rows. %{errors}"
```

- [ ] **Step 8: 執行測試，確認通過**

Run: `bundle exec rspec spec/requests/parcel_imports_spec.rb`
Expected: PASS（8 examples）

若 `assigns_summary` 在 request spec 中取不到 controller instance，改為直接斷言 `response.body` 內容（頁面上已渲染 create/overwrite/unmatched 數字），刪除該 helper。

- [ ] **Step 9: RuboCop 與 commit**

```bash
bin/rubocop -a app/controllers/parcels_controller.rb app/models/membership.rb spec/requests/parcel_imports_spec.rb
git add app/controllers/parcels_controller.rb app/views/parcels config/routes.rb app/models/membership.rb config/locales spec/requests/parcel_imports_spec.rb
git commit -m "feat(shipping): Excel bill import with preview gate (owner-only)"
```

---

### Task 5: 差異報表 Index、未配對分頁、inline edit

**Files:**
- Modify: `app/controllers/parcels_controller.rb`
- Create: `app/views/parcels/index.html.erb`
- Create: `app/views/parcels/_parcel_row.html.erb`
- Create: `app/views/parcels/update.turbo_stream.erb`
- Modify: `config/locales/*.yml`
- Create: `spec/requests/parcels_spec.rb`

**Interfaces:**
- Consumes: Task 1 `Order#shipping_variance`、`#shipping_variance_pct`、`#parcel_count`；Task 4 的 `require_owner!`
- Produces: `parcels_path`（Index，支援 `tab=unmatched`、`sort_column`、`sort_direction`、`from_date`、`to_date`、`multi_parcel_only`、`over_only`）

- [ ] **Step 1: 寫失敗的 request spec**

`spec/requests/parcels_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe "Parcels", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }

  let!(:cheap) do
    o = create(:order, customer: customer, shopify_store: store, name: "PKS#3001",
                       estimated_shipping_cost: 10, ordered_at: 2.days.ago)
    create(:parcel, shopify_store: store, order: o, identifier: "A1", cost_amount: 11)
    o
  end

  let!(:blown) do
    o = create(:order, customer: customer, shopify_store: store, name: "PKS#3052",
                       estimated_shipping_cost: 18.20, ordered_at: 1.day.ago)
    create(:parcel, shopify_store: store, order: o, identifier: "B1", cost_amount: 20)
    create(:parcel, shopify_store: store, order: o, identifier: "B2", cost_amount: 20.10)
    o
  end

  before { sign_in user }

  describe "GET /parcels" do
    it "lists orders with their estimated, actual and variance" do
      get parcels_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("PKS#3052")
      expect(response.body).to include("PKS#3001")
    end

    it "sorts by variance descending by default (worst overrun first)" do
      get parcels_path
      expect(response.body.index("PKS#3052")).to be < response.body.index("PKS#3001")
    end

    it "filters to multi-parcel orders only" do
      get parcels_path, params: { multi_parcel_only: "1" }
      expect(response.body).to include("PKS#3052")
      expect(response.body).not_to include("PKS#3001")
    end

    it "filters to overrun orders only" do
      saver = create(:order, customer: customer, shopify_store: store, name: "PKS#3009",
                             estimated_shipping_cost: 50, ordered_at: 1.day.ago)
      create(:parcel, shopify_store: store, order: saver, identifier: "C1", cost_amount: 10)

      get parcels_path, params: { over_only: "1" }
      expect(response.body).not_to include("PKS#3009")
      expect(response.body).to include("PKS#3052")
    end

    it "shows unmatched parcels on the unmatched tab" do
      create(:parcel, shopify_store: store, order: nil, identifier: "ORPHAN1")

      get parcels_path, params: { tab: "unmatched" }
      expect(response.body).to include("ORPHAN1")
    end

    it "denies a member without the parcels permission" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [])
      sign_out user
      sign_in member

      get parcels_path
      expect(response).to redirect_to(authenticated_root_path)
    end

    it "allows a member who has the parcels permission" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      get parcels_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /parcels/:id" do
    it "updates the cost and re-rolls up the order" do
      parcel = blown.parcels.find_by(identifier: "B1")

      patch parcel_path(parcel), params: { parcel: { cost_cny: "72.00" } }

      expect(parcel.reload.cost_cny).to eq(72)
      expect(parcel.cost_amount).to eq(10)             # 72 / 7.2, recomputed on write
      expect(blown.reload.actual_shipping_cost).to eq(30.10)
    end

    it "assigns an unmatched parcel to an order and rolls up" do
      orphan = create(:parcel, shopify_store: store, order: nil, identifier: "ORPHAN1", cost_amount: 5)

      patch parcel_path(orphan), params: { parcel: { order_id: cheap.id } }

      expect(orphan.reload.order_id).to eq(cheap.id)
      expect(cheap.reload.actual_shipping_cost).to eq(16)   # 11 + 5
    end

    it "rejects a non-owner member" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      patch parcel_path(blown.parcels.first), params: { parcel: { cost_cny: "1" } }
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "DELETE /parcels/:id" do
    it "destroys the parcel and re-rolls up" do
      parcel = cheap.parcels.first

      delete parcel_path(parcel)

      expect(cheap.reload.actual_shipping_cost).to be_nil
    end
  end
end
```

- [ ] **Step 2: 執行測試，確認失敗**

Run: `bundle exec rspec spec/requests/parcels_spec.rb`
Expected: FAIL — `parcels_path` 對應的 `index` action 不存在（`AbstractController::ActionNotFound`）

- [ ] **Step 3: 補上 Index / update / destroy**

在 `app/controllers/parcels_controller.rb` 的 `CACHE_TTL` 常數下方加入：

```ruby
  SORTABLE = {
    "variance"  => "(orders.actual_shipping_cost - orders.estimated_shipping_cost)",
    "ordered_at" => "orders.ordered_at",
    "actual"    => "orders.actual_shipping_cost",
    "estimated" => "orders.estimated_shipping_cost"
  }.freeze
  PER_PAGE = 25
```

並在 `import` action **之前**加入 `index`，在 `private` **之前**加入 `update` / `destroy`：

```ruby
  def index
    @tab = params[:tab] == "unmatched" ? "unmatched" : "orders"
    @page = [ params[:page].to_i, 1 ].max
    store_ids = visible_shopify_stores.pluck(:id)

    parse_dates

    if @tab == "unmatched"
      base = Parcel.unmatched.where(shopify_store_id: store_ids).order(shipped_at: :desc)
      @total_count = base.count
      @total_pages = (@total_count.to_f / PER_PAGE).ceil
      @page = [ @page, @total_pages ].min if @total_pages.positive?
      @parcels = base.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
      @assignable_orders = Order.where(shopify_store_id: store_ids)
                                .where.not(name: nil)
                                .order(ordered_at: :desc)
                                .limit(200)
      return
    end

    @sort_column    = SORTABLE.key?(params[:sort_column]) ? params[:sort_column] : "variance"
    @sort_direction = params[:sort_direction] == "asc" ? "asc" : "desc"

    base = Order.where(shopify_store_id: store_ids)
                .where.not(actual_shipping_cost: nil)
                .ordered_between(@from_time, @to_time)

    base = base.where(id: Parcel.group(:order_id).having("COUNT(*) > 1").select(:order_id)) if params[:multi_parcel_only].present?
    base = base.where("orders.actual_shipping_cost > orders.estimated_shipping_cost") if params[:over_only].present?

    @total_count = base.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @page = [ @page, @total_pages ].min if @total_pages.positive?

    @orders = base
      .includes(:parcels)
      .reorder(Arel.sql("#{SORTABLE.fetch(@sort_column)} #{@sort_direction} NULLS LAST"))
      .offset((@page - 1) * PER_PAGE)
      .limit(PER_PAGE)
  end

  def update
    parcel = scoped_parcels.find(params[:id])

    if parcel.update(recomputed_attrs(parcel))
      respond_to do |format|
        format.turbo_stream { @parcel = parcel.reload }
        format.html { redirect_to parcels_path, notice: t("parcels.updated") }
      end
    else
      redirect_to parcels_path, alert: parcel.errors.full_messages.join(", ")
    end
  end

  def destroy
    parcel = scoped_parcels.find(params[:id])
    parcel.destroy!
    redirect_to parcels_path(request.query_parameters.slice(:tab, :from_date, :to_date)),
                notice: t("parcels.destroyed")
  end
```

在 `private` 區塊加入：

```ruby
  def scoped_parcels
    Parcel.where(shopify_store_id: visible_shopify_stores.select(:id))
  end

  def parcel_params
    params.require(:parcel).permit(:cost_cny, :order_id, :service_channel, :billed_weight_g)
  end

  # cost_amount is derived, never user-supplied: if the operator corrects the CNY
  # figure, the store-currency figure (and therefore the order rollup) must follow.
  def recomputed_attrs(parcel)
    attrs = parcel_params.to_h.symbolize_keys

    if attrs.key?(:order_id) && attrs[:order_id].present?
      # Never let a parcel be attached to an order in another company's store.
      attrs[:order_id] = Order.where(shopify_store_id: visible_shopify_stores.select(:id))
                              .where(id: attrs[:order_id]).pick(:id)
    end

    if attrs[:cost_cny].present?
      fx = parcel.fx_rate_snapshot.presence || parcel.shopify_store.cost_fx_rate
      attrs[:cost_amount] = (BigDecimal(attrs[:cost_cny].to_s) / BigDecimal(fx.to_s)).round(2) if fx&.positive?
    end

    attrs
  end

  def parse_dates
    tz = store_timezone
    today = Time.current.in_time_zone(tz).to_date
    @from_date = params[:from_date].present? ? Date.parse(params[:from_date]) : today - 30
    @to_date   = params[:to_date].present?   ? Date.parse(params[:to_date])   : today
    @from_time = tz.parse(@from_date.to_s).beginning_of_day.utc
    @to_time   = tz.parse(@to_date.to_s).end_of_day.utc
  rescue Date::Error
    @from_date = today - 30
    @to_date   = today
    @from_time = tz.parse(@from_date.to_s).beginning_of_day.utc
    @to_time   = tz.parse(@to_date.to_s).end_of_day.utc
  end
```

- [ ] **Step 4: 建立 Index view**

`app/views/parcels/index.html.erb`：

```erb
<div class="p-6">
  <div class="flex items-center justify-between mb-6">
    <h1 class="text-2xl font-semibold text-gray-900"><%= t("parcels.title") %></h1>
    <% if current_membership&.owner? %>
      <%= link_to t("parcels.import.title"), import_parcels_path,
            class: "px-4 py-2 bg-gray-900 text-white text-sm font-medium rounded-md hover:bg-gray-800" %>
    <% end %>
  </div>

  <nav class="flex gap-4 border-b border-gray-200 mb-4">
    <%= link_to t("parcels.tab_orders"), parcels_path,
          class: "pb-2 text-sm font-medium #{@tab == 'orders' ? 'border-b-2 border-gray-900 text-gray-900' : 'text-gray-500 hover:text-gray-700'}" %>
    <%= link_to t("parcels.tab_unmatched"), parcels_path(tab: "unmatched"),
          class: "pb-2 text-sm font-medium #{@tab == 'unmatched' ? 'border-b-2 border-gray-900 text-gray-900' : 'text-gray-500 hover:text-gray-700'}" %>
  </nav>

  <% if @tab == "unmatched" %>
    <table class="min-w-full divide-y divide-gray-200 bg-white rounded-lg border border-gray-200">
      <thead class="bg-gray-50">
        <tr>
          <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase"><%= t("parcels.columns.identifier") %></th>
          <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase"><%= t("parcels.columns.tracking") %></th>
          <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase"><%= t("parcels.columns.channel") %></th>
          <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase"><%= t("parcels.columns.cost") %></th>
          <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase"><%= t("parcels.columns.assign") %></th>
        </tr>
      </thead>
      <tbody class="divide-y divide-gray-100">
        <% @parcels.each do |parcel| %>
          <tr>
            <td class="px-4 py-3 text-sm font-medium text-gray-900"><%= parcel.identifier %></td>
            <td class="px-4 py-3 text-sm text-gray-500"><%= parcel.tracking_number %></td>
            <td class="px-4 py-3 text-sm text-gray-500"><%= parcel.service_channel %></td>
            <td class="px-4 py-3 text-sm text-right text-gray-900"><%= number_to_currency(parcel.cost_amount) %></td>
            <td class="px-4 py-3">
              <% if current_membership&.owner? %>
                <%= form_with url: parcel_path(parcel), method: :patch, class: "flex gap-2" do %>
                  <%= select_tag "parcel[order_id]",
                        options_from_collection_for_select(@assignable_orders, :id, :name),
                        include_blank: true,
                        class: "rounded-md border-gray-300 text-sm" %>
                  <%= submit_tag t("parcels.assign"),
                        class: "px-3 py-1 text-sm border border-gray-300 rounded-md hover:bg-gray-50 cursor-pointer" %>
                <% end %>
              <% end %>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% else %>
    <%= form_tag parcels_path, method: :get, class: "bg-white rounded-lg border border-gray-200 p-4 mb-4 flex flex-wrap gap-4 items-end" do %>
      <div>
        <label for="from_date" class="block text-xs font-medium text-gray-500 mb-1"><%= t("parcels.from_date") %></label>
        <%= date_field_tag :from_date, @from_date, class: "rounded-md border-gray-300 text-sm" %>
      </div>
      <div>
        <label for="to_date" class="block text-xs font-medium text-gray-500 mb-1"><%= t("parcels.to_date") %></label>
        <%= date_field_tag :to_date, @to_date, class: "rounded-md border-gray-300 text-sm" %>
      </div>
      <label class="flex items-center gap-2 text-sm text-gray-700">
        <%= check_box_tag :multi_parcel_only, "1", params[:multi_parcel_only].present?, class: "rounded border-gray-300" %>
        <%= t("parcels.multi_parcel_only") %>
      </label>
      <label class="flex items-center gap-2 text-sm text-gray-700">
        <%= check_box_tag :over_only, "1", params[:over_only].present?, class: "rounded border-gray-300" %>
        <%= t("parcels.over_only") %>
      </label>
      <%= submit_tag t("parcels.filter"), class: "px-4 py-2 bg-gray-900 text-white text-sm rounded-md cursor-pointer" %>
    <% end %>

    <table class="min-w-full divide-y divide-gray-200 bg-white rounded-lg border border-gray-200">
      <thead class="bg-gray-50">
        <tr>
          <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase"><%= t("parcels.columns.order") %></th>
          <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase"><%= t("parcels.columns.estimated") %></th>
          <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase"><%= t("parcels.columns.actual") %></th>
          <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
            <%= link_to t("parcels.columns.variance"),
                  parcels_path(request.query_parameters.merge(sort_column: "variance",
                    sort_direction: (@sort_column == "variance" && @sort_direction == "desc") ? "asc" : "desc")),
                  class: "hover:text-gray-700" %>
          </th>
          <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase"><%= t("parcels.columns.variance_pct") %></th>
          <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase"><%= t("parcels.columns.parcel_count") %></th>
        </tr>
      </thead>
      <tbody class="divide-y divide-gray-100">
        <% @orders.each do |order| %>
          <tr>
            <td class="px-4 py-3 text-sm font-medium text-gray-900"><%= order.name %></td>
            <td class="px-4 py-3 text-sm text-right text-gray-500"><%= order.estimated_shipping_cost ? number_to_currency(order.estimated_shipping_cost) : "—" %></td>
            <td class="px-4 py-3 text-sm text-right text-gray-900"><%= number_to_currency(order.actual_shipping_cost) %></td>
            <td class="px-4 py-3 text-sm text-right font-medium <%= order.shipping_variance.to_f.positive? ? "text-red-600" : "text-green-600" %>">
              <%= order.shipping_variance ? number_to_currency(order.shipping_variance) : "—" %>
            </td>
            <td class="px-4 py-3 text-sm text-right text-gray-500">
              <%= order.shipping_variance_pct ? "#{order.shipping_variance_pct}%" : "—" %>
            </td>
            <td class="px-4 py-3 text-sm text-right <%= order.parcels.size > 1 ? "text-amber-600 font-medium" : "text-gray-500" %>">
              <%= order.parcels.size %>
            </td>
          </tr>
          <tr class="bg-gray-50">
            <td colspan="6" class="px-4 py-2">
              <table class="min-w-full text-xs">
                <thead>
                  <tr class="text-gray-500">
                    <th class="py-1 text-left"><%= t("parcels.columns.identifier") %></th>
                    <th class="py-1 text-left"><%= t("parcels.columns.channel") %></th>
                    <th class="py-1 text-right"><%= t("parcels.columns.billed_weight") %></th>
                    <th class="py-1 text-right"><%= t("parcels.columns.freight") %></th>
                    <th class="py-1 text-right"><%= t("parcels.columns.registration") %></th>
                    <th class="py-1 text-right"><%= t("parcels.columns.operation") %></th>
                    <th class="py-1 text-right"><%= t("parcels.columns.cost_cny") %></th>
                    <th class="py-1 text-right"><%= t("parcels.columns.cost") %></th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <% order.parcels.each do |parcel| %>
                    <%= render "parcels/parcel_row", parcel: parcel %>
                  <% end %>
                </tbody>
              </table>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% end %>
</div>
```

`app/views/parcels/_parcel_row.html.erb`：

```erb
<tr id="<%= dom_id(parcel) %>">
  <td class="py-1 text-gray-900"><%= parcel.identifier %></td>
  <td class="py-1 text-gray-500"><%= parcel.service_channel %></td>
  <td class="py-1 text-right text-gray-500"><%= parcel.billed_weight_g %>g</td>
  <td class="py-1 text-right text-gray-500">¥<%= parcel.freight_cny %></td>
  <td class="py-1 text-right text-gray-500">¥<%= parcel.registration_fee_cny %></td>
  <td class="py-1 text-right text-gray-500">¥<%= parcel.operation_fee_cny %></td>
  <td class="py-1 text-right text-gray-900">¥<%= parcel.cost_cny %></td>
  <td class="py-1 text-right font-medium text-gray-900"><%= number_to_currency(parcel.cost_amount) %></td>
  <td class="py-1 text-right">
    <% if current_membership&.owner? %>
      <%= form_with url: parcel_path(parcel), method: :patch, class: "inline-flex gap-1 items-center" do %>
        <%= number_field_tag "parcel[cost_cny]", parcel.cost_cny, step: "0.01",
              class: "w-20 rounded border-gray-300 text-xs py-0.5",
              "aria-label": t("parcels.columns.cost_cny") %>
        <%= submit_tag t("parcels.save"), class: "px-2 py-0.5 text-xs border border-gray-300 rounded hover:bg-gray-100 cursor-pointer" %>
      <% end %>
      <%= button_to t("parcels.delete"), parcel_path(parcel), method: :delete,
            form: { data: { turbo_confirm: t("parcels.delete_confirm") } },
            class: "px-2 py-0.5 text-xs text-red-600 hover:underline" %>
    <% end %>
  </td>
</tr>
```

`app/views/parcels/update.turbo_stream.erb`：

```erb
<%= turbo_stream.replace dom_id(@parcel) do %>
  <%= render "parcels/parcel_row", parcel: @parcel %>
<% end %>
```

- [ ] **Step 5: 加入 i18n**

`config/locales/zh-TW.yml` 的 `parcels:` 區塊內（與 `import:` 同層）加入：

```yaml
    title: "運費差異"
    tab_orders: "訂單差異"
    tab_unmatched: "未配對包裹"
    from_date: "起始日期"
    to_date: "結束日期"
    multi_parcel_only: "只看多包裹訂單"
    over_only: "只看超支"
    filter: "篩選"
    assign: "指派"
    save: "儲存"
    delete: "刪除"
    delete_confirm: "確定要刪除這個包裹嗎？該訂單的實際運費會重新計算。"
    updated: "包裹已更新"
    destroyed: "包裹已刪除"
    columns:
      order: "訂單"
      estimated: "預估運費"
      actual: "實際運費"
      variance: "差異"
      variance_pct: "差異 %"
      parcel_count: "包裹數"
      identifier: "包裹識別號"
      tracking: "貨運單號"
      channel: "物流渠道"
      billed_weight: "計費重"
      freight: "運費"
      registration: "掛號費"
      operation: "操作費"
      cost_cny: "帳單金額"
      cost: "換算金額"
      assign: "指派訂單"
```

`config/locales/zh-CN.yml`：

```yaml
    title: "运费差异"
    tab_orders: "订单差异"
    tab_unmatched: "未匹配包裹"
    from_date: "起始日期"
    to_date: "结束日期"
    multi_parcel_only: "只看多包裹订单"
    over_only: "只看超支"
    filter: "筛选"
    assign: "指派"
    save: "保存"
    delete: "删除"
    delete_confirm: "确定要删除这个包裹吗？该订单的实际运费会重新计算。"
    updated: "包裹已更新"
    destroyed: "包裹已删除"
    columns:
      order: "订单"
      estimated: "预估运费"
      actual: "实际运费"
      variance: "差异"
      variance_pct: "差异 %"
      parcel_count: "包裹数"
      identifier: "包裹识别号"
      tracking: "货运单号"
      channel: "物流渠道"
      billed_weight: "计费重"
      freight: "运费"
      registration: "挂号费"
      operation: "操作费"
      cost_cny: "账单金额"
      cost: "换算金额"
      assign: "指派订单"
```

`config/locales/en.yml`：

```yaml
    title: "Shipping variance"
    tab_orders: "Order variance"
    tab_unmatched: "Unmatched parcels"
    from_date: "From"
    to_date: "To"
    multi_parcel_only: "Multi-parcel orders only"
    over_only: "Overruns only"
    filter: "Filter"
    assign: "Assign"
    save: "Save"
    delete: "Delete"
    delete_confirm: "Delete this parcel? The order's actual shipping cost will be recalculated."
    updated: "Parcel updated"
    destroyed: "Parcel deleted"
    columns:
      order: "Order"
      estimated: "Estimated"
      actual: "Actual"
      variance: "Variance"
      variance_pct: "Variance %"
      parcel_count: "Parcels"
      identifier: "Parcel ID"
      tracking: "Tracking no."
      channel: "Channel"
      billed_weight: "Billed weight"
      freight: "Freight"
      registration: "Registration fee"
      operation: "Handling fee"
      cost_cny: "Billed (CNY)"
      cost: "Converted"
      assign: "Assign order"
```

- [ ] **Step 6: 執行測試，確認通過**

Run: `bundle exec rspec spec/requests/parcels_spec.rb`
Expected: PASS（11 examples）

- [ ] **Step 7: RuboCop 與 commit**

```bash
bin/rubocop -a app/controllers/parcels_controller.rb spec/requests/parcels_spec.rb
git add app/controllers/parcels_controller.rb app/views/parcels config/locales spec/requests/parcels_spec.rb
git commit -m "feat(shipping): order-level variance report with parcel drill-down and inline edit"
```

---

### Task 6: Company agent API key + Parcel API

**Files:**
- Create: `db/migrate/20260714120002_add_agent_api_key_to_companies.rb`
- Modify: `app/models/company.rb`
- Modify: `app/controllers/companies_controller.rb`
- Create: `app/controllers/api/company_base_controller.rb`
- Create: `app/controllers/api/v1/parcels_controller.rb`
- Create: `app/controllers/api/v1/orders_controller.rb`
- Modify: `config/routes.rb`
- Modify: `app/views/companies/edit.html.erb`
- Modify: `config/locales/*.yml`
- Create: `spec/requests/api/v1/parcels_spec.rb`
- Modify: `spec/models/company_spec.rb`

**Interfaces:**
- Consumes: Task 3 `ParcelUpserter`
- Produces: `Company#regenerate_agent_api_key!`；`Api::CompanyBaseController#current_company`；API 端點五個

- [ ] **Step 1: migration**

`db/migrate/20260714120002_add_agent_api_key_to_companies.rb`：

```ruby
class AddAgentApiKeyToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :agent_api_key, :string
    add_index  :companies, :agent_api_key, unique: true
  end
end
```

Run: `bin/rails db:migrate && bin/rails db:test:prepare`

- [ ] **Step 2: 寫失敗的 API request spec**

`spec/requests/api/v1/parcels_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe "Api::V1::Parcels", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:order)   { create(:order, customer: customer, shopify_store: store, name: "PKS#3037", estimated_shipping_cost: 20) }

  before { company.regenerate_agent_api_key! }

  def auth_headers(key = company.agent_api_key)
    { "Authorization" => "Bearer #{key}" }
  end

  def payload(over = {})
    {
      shopify_store_id: store.id,
      identifier: "XMBDE2012381",
      order_name: "PKS#3037",
      cost_cny: "239.73",
      service_channel: "美国标准（A带电）",
      billed_weight_g: 2421
    }.merge(over)
  end

  describe "authentication" do
    it "rejects a request with no key" do
      get "/api/v1/parcels"
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects an EmailAccount agent key (wrong principal)" do
      account = create(:email_account, company: company, user: user)

      get "/api/v1/parcels", headers: auth_headers(account.agent_api_key)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/parcels" do
    it "creates a parcel, links the order and rolls up" do
      expect {
        post "/api/v1/parcels", params: payload, headers: auth_headers
      }.to change(Parcel, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["identifier"]).to eq("XMBDE2012381")
      expect(body["cost_amount"].to_f).to eq(33.30)
      expect(body["order_name"]).to eq("PKS#3037")
      expect(order.reload.actual_shipping_cost).to eq(33.30)
    end

    it "is an upsert — posting the same identifier twice updates, never duplicates" do
      post "/api/v1/parcels", params: payload, headers: auth_headers
      expect {
        post "/api/v1/parcels", params: payload(cost_cny: "100.00"), headers: auth_headers
      }.not_to change(Parcel, :count)

      expect(Parcel.last.cost_cny).to eq(100)
    end

    it "422s when the store has no fx rate" do
      store.update!(cost_fx_rate: nil)
      post "/api/v1/parcels", params: payload, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "404s for a store outside the company" do
      other = create(:shopify_store, user: create(:user), cost_fx_rate: 7)
      post "/api/v1/parcels", params: payload(shopify_store_id: other.id), headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/parcels" do
    before { post "/api/v1/parcels", params: payload, headers: auth_headers }

    it "lists parcels" do
      get "/api/v1/parcels", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).size).to eq(1)
    end

    it "filters by order_name" do
      get "/api/v1/parcels", params: { order_name: "PKS#9999" }, headers: auth_headers
      expect(JSON.parse(response.body)).to be_empty
    end

    it "filters unmatched" do
      post "/api/v1/parcels", params: payload(identifier: "ORPHAN1", order_name: "PKS#9999"), headers: auth_headers

      get "/api/v1/parcels", params: { unmatched: "true" }, headers: auth_headers

      body = JSON.parse(response.body)
      expect(body.map { |p| p["identifier"] }).to eq([ "ORPHAN1" ])
    end
  end

  describe "GET /api/v1/parcels/:identifier" do
    before { post "/api/v1/parcels", params: payload, headers: auth_headers }

    it "returns the parcel" do
      get "/api/v1/parcels/XMBDE2012381", headers: auth_headers
      expect(JSON.parse(response.body)["identifier"]).to eq("XMBDE2012381")
    end

    it "404s for an unknown identifier" do
      get "/api/v1/parcels/NOPE", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/parcels/:identifier" do
    before { post "/api/v1/parcels", params: payload, headers: auth_headers }

    it "updates the cost and re-rolls up" do
      patch "/api/v1/parcels/XMBDE2012381", params: { cost_cny: "72.00" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(order.reload.actual_shipping_cost).to eq(10)
    end
  end

  describe "GET /api/v1/orders/:name/shipping" do
    before { post "/api/v1/parcels", params: payload, headers: auth_headers }

    it "returns estimated, actual, variance and the parcel breakdown" do
      get "/api/v1/orders/#{CGI.escape('PKS#3037')}/shipping", headers: auth_headers

      body = JSON.parse(response.body)
      expect(body["estimated_shipping_cost"].to_f).to eq(20.0)
      expect(body["actual_shipping_cost"].to_f).to eq(33.30)
      expect(body["variance"].to_f).to eq(13.30)
      expect(body["parcels"].size).to eq(1)
    end

    it "404s for an unknown order" do
      get "/api/v1/orders/PKS%239999/shipping", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
```

在 `spec/models/company_spec.rb` 追加：

```ruby
  describe "#regenerate_agent_api_key!" do
    it "generates a key and can be found by it" do
      company = create(:company)
      company.regenerate_agent_api_key!

      expect(company.agent_api_key).to be_present
      expect(Company.find_by(agent_api_key: company.agent_api_key)).to eq(company)
    end

    it "replaces the previous key" do
      company = create(:company)
      company.regenerate_agent_api_key!
      first = company.agent_api_key
      company.regenerate_agent_api_key!

      expect(company.agent_api_key).not_to eq(first)
    end
  end
```

- [ ] **Step 3: 執行測試，確認失敗**

Run: `bundle exec rspec spec/requests/api/v1/parcels_spec.rb`
Expected: FAIL — `undefined method 'regenerate_agent_api_key!'`

- [ ] **Step 4: Company model**

`app/models/company.rb`，在 `encrypts :tracking_api_key, deterministic: false` 下方加入：

```ruby
  # Deterministic so that find_by(agent_api_key:) works for API authentication.
  encrypts :agent_api_key, deterministic: true
```

在 `validates :tracking_backfill_days, ...` 之後加入：

```ruby
  validates :agent_api_key, uniqueness: true, allow_nil: true
```

在 `def tracking_api_key_configured?` 之前加入：

```ruby
  def regenerate_agent_api_key!
    update!(agent_api_key: SecureRandom.urlsafe_base64(32))
  end
```

- [ ] **Step 5: API base controller**

`app/controllers/api/company_base_controller.rb`：

```ruby
# Authenticates an AI agent against a COMPANY key, not an EmailAccount key.
# Parcels are company financial data (Order → ShopifyStore → Company); the
# ticket API's EmailAccount principal is the wrong scope for them, so this is a
# separate base class and Api::BaseController stays untouched.
class Api::CompanyBaseController < ActionController::API
  before_action :authenticate_company_key!

  attr_reader :current_company

  private

  def authenticate_company_key!
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    return render_unauthorized if token.blank?

    @current_company = Company.find_by(agent_api_key: token)
    render_unauthorized unless @current_company
  end

  def render_unauthorized
    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def company_stores
    current_company.shopify_stores
  end

  def company_parcels
    Parcel.where(shopify_store_id: company_stores.select(:id))
  end
end
```

- [ ] **Step 6: API controllers**

`app/controllers/api/v1/parcels_controller.rb`：

```ruby
class Api::V1::ParcelsController < Api::CompanyBaseController
  def index
    parcels = company_parcels.includes(:order)
    parcels = parcels.unmatched if params[:unmatched].to_s == "true"

    if params[:order_name].present?
      order_ids = Order.where(shopify_store_id: company_stores.select(:id), name: params[:order_name]).select(:id)
      parcels = parcels.where(order_id: order_ids)
    end

    if params[:from].present? && params[:to].present?
      parcels = parcels.where(shipped_at: Time.zone.parse(params[:from])..Time.zone.parse(params[:to]))
    end

    render json: parcels.order(shipped_at: :desc).limit(500).map { |p| parcel_json(p) }
  end

  def show
    render json: parcel_json(find_parcel!)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Parcel not found" }, status: :not_found
  end

  def create
    store = company_stores.find_by(id: params[:shopify_store_id])
    return render(json: { error: "Store not found" }, status: :not_found) unless store

    parcel = ParcelUpserter.new(store: store, attrs: upsert_params).call
    render json: parcel_json(parcel), status: :created
  rescue ParcelUpserter::MissingFxRate
    render json: { error: "Store has no cost_fx_rate configured" }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Validation failed", details: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    parcel = find_parcel!
    attrs = upsert_params.merge(identifier: parcel.identifier)
    attrs[:order_name] = parcel.order&.name unless params.key?(:order_name)

    updated = ParcelUpserter.new(store: parcel.shopify_store, attrs: attrs).call
    render json: parcel_json(updated)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Parcel not found" }, status: :not_found
  rescue ParcelUpserter::MissingFxRate
    render json: { error: "Store has no cost_fx_rate configured" }, status: :unprocessable_entity
  end

  private

  def find_parcel!
    company_parcels.find_by!(identifier: params[:identifier])
  end

  UPSERT_KEYS = %i[
    identifier order_name internal_no tracking_number shipped_at service_channel
    zone country actual_weight_g billed_weight_g
    cost_cny freight_cny registration_fee_cny tax_cny remote_area_fee_cny operation_fee_cny
  ].freeze

  def upsert_params
    params.permit(*UPSERT_KEYS).to_h.symbolize_keys
  end

  def parcel_json(parcel)
    {
      id: parcel.id,
      identifier: parcel.identifier,
      internal_no: parcel.internal_no,
      tracking_number: parcel.tracking_number,
      order_name: parcel.order&.name,
      matched: parcel.order_id.present?,
      shipped_at: parcel.shipped_at,
      service_channel: parcel.service_channel,
      zone: parcel.zone,
      country: parcel.country,
      actual_weight_g: parcel.actual_weight_g,
      billed_weight_g: parcel.billed_weight_g,
      cost_cny: parcel.cost_cny,
      freight_cny: parcel.freight_cny,
      registration_fee_cny: parcel.registration_fee_cny,
      tax_cny: parcel.tax_cny,
      remote_area_fee_cny: parcel.remote_area_fee_cny,
      operation_fee_cny: parcel.operation_fee_cny,
      fx_rate_snapshot: parcel.fx_rate_snapshot,
      cost_amount: parcel.cost_amount
    }
  end
end
```

`app/controllers/api/v1/orders_controller.rb`：

```ruby
class Api::V1::OrdersController < Api::CompanyBaseController
  def shipping
    order = Order.where(shopify_store_id: company_stores.select(:id))
                 .includes(:parcels)
                 .find_by!(name: params[:name])

    render json: {
      order_name: order.name,
      currency: order.currency,
      estimated_shipping_cost: order.estimated_shipping_cost,
      actual_shipping_cost: order.actual_shipping_cost,
      variance: order.shipping_variance,
      variance_pct: order.shipping_variance_pct,
      parcel_count: order.parcels.size,
      parcels: order.parcels.map do |p|
        {
          identifier: p.identifier,
          tracking_number: p.tracking_number,
          service_channel: p.service_channel,
          billed_weight_g: p.billed_weight_g,
          cost_cny: p.cost_cny,
          registration_fee_cny: p.registration_fee_cny,
          operation_fee_cny: p.operation_fee_cny,
          cost_amount: p.cost_amount
        }
      end
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Order not found" }, status: :not_found
  end
end
```

- [ ] **Step 7: 路由**

`config/routes.rb` 的 `namespace :api → namespace :v1` 區塊內，`resources :tickets` 之後加入：

```ruby
      resources :parcels, only: [ :index, :show, :create, :update ], param: :identifier
      get "orders/:name/shipping", to: "orders#shipping", constraints: { name: /[^\/]+/ }
```

並在 `scope "(:locale)"` 內 `resource :company, only: [ :new, :create, :edit, :update ]` 之後加入：

```ruby
    post "company/agent_api_key", to: "companies#regenerate_agent_api_key", as: :regenerate_company_agent_api_key
```

- [ ] **Step 8: Companies controller + view**

`app/controllers/companies_controller.rb` 加入 action（放在 `update` 之後、`private` 之前）：

```ruby
  def regenerate_agent_api_key
    return redirect_to(edit_company_path, alert: t("companies.no_permission")) unless current_membership&.owner?

    current_company.regenerate_agent_api_key!
    flash[:reveal_agent_api_key] = true
    redirect_to edit_company_path, notice: t("companies.agent_api_key.regenerated")
  end
```

`app/views/companies/edit.html.erb` 結尾（最後一個容器 div 內）加入：

```erb
<% if current_membership&.owner? %>
  <section class="mt-8 bg-white rounded-lg border border-gray-200 p-6">
    <h2 class="text-lg font-medium text-gray-900"><%= t("companies.agent_api_key.title") %></h2>
    <p class="mt-1 text-sm text-gray-500"><%= t("companies.agent_api_key.hint") %></p>

    <div class="mt-4 flex items-center gap-3">
      <code class="px-3 py-2 bg-gray-50 border border-gray-200 rounded text-sm font-mono">
        <% if flash[:reveal_agent_api_key] && current_company.agent_api_key.present? %>
          <%= current_company.agent_api_key %>
        <% elsif current_company.agent_api_key.present? %>
          ••••••••••••••••
        <% else %>
          —
        <% end %>
      </code>
      <%= button_to t("companies.agent_api_key.regenerate"), regenerate_company_agent_api_key_path,
            method: :post,
            form: { data: { turbo_confirm: t("companies.agent_api_key.regenerate_confirm") } },
            class: "px-3 py-2 border border-gray-300 text-sm rounded-md hover:bg-gray-50" %>
    </div>
  </section>
<% end %>
```

i18n（`zh-TW.yml` 的 `companies:` 區塊下）：

```yaml
    agent_api_key:
      title: "Agent API 金鑰"
      hint: "供 AI agent 讀寫運費資料。只會在重新產生後顯示一次，請妥善保存。"
      regenerate: "重新產生"
      regenerate_confirm: "重新產生後，舊金鑰會立即失效。確定要繼續嗎？"
      regenerated: "已產生新的 Agent API 金鑰"
```

`zh-CN.yml`：

```yaml
    agent_api_key:
      title: "Agent API 密钥"
      hint: "供 AI agent 读写运费数据。只会在重新生成后显示一次，请妥善保存。"
      regenerate: "重新生成"
      regenerate_confirm: "重新生成后，旧密钥会立即失效。确定要继续吗？"
      regenerated: "已生成新的 Agent API 密钥"
```

`en.yml`：

```yaml
    agent_api_key:
      title: "Agent API key"
      hint: "Lets an AI agent read and write shipping cost data. Shown only once after regeneration — store it somewhere safe."
      regenerate: "Regenerate"
      regenerate_confirm: "Regenerating immediately invalidates the old key. Continue?"
      regenerated: "New Agent API key generated"
```

- [ ] **Step 9: 執行測試，確認通過**

Run: `bundle exec rspec spec/requests/api/v1/parcels_spec.rb spec/models/company_spec.rb spec/requests/api/v1/tickets_spec.rb`
Expected: PASS —— **ticket API 的既有 spec 必須全綠**（證明沒有破壞既有認證）。

- [ ] **Step 10: RuboCop 與 commit**

```bash
bin/rubocop -a app/controllers/api app/models/company.rb app/controllers/companies_controller.rb spec/requests/api
git add db/migrate db/schema.rb app/models/company.rb app/controllers/api app/controllers/companies_controller.rb app/views/companies config/routes.rb config/locales spec/requests/api spec/models/company_spec.rb
git commit -m "feat(shipping): company-scoped agent API for parcel CRUD and order shipping variance"
```

---

### Task 7: Dashboard 物流 Section

**Files:**
- Modify: `app/services/dashboard_metrics_service.rb`
- Create: `app/views/dashboard/_shipping_section.html.erb`
- Modify: `app/views/dashboard/show.html.erb`
- Modify: `config/locales/*.yml`
- Modify: `spec/services/dashboard_metrics_service_spec.rb`
- Create: `spec/requests/dashboard_shipping_spec.rb`

**Interfaces:**
- Consumes: Task 1 的 rollup（`orders.actual_shipping_cost`）
- Produces: metrics 新增 key：`shipping_estimated_total`、`shipping_actual_total`、`shipping_variance`、`shipping_variance_pct`、`multi_parcel_orders_count`

- [ ] **Step 1: 寫失敗的 service spec**

在 `spec/services/dashboard_metrics_service_spec.rb` 追加：

```ruby
  describe "shipping variance metrics" do
    let(:user)  { create(:user) }
    let(:company) { user.companies.first }
    let(:store) { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2, timezone: "UTC") }
    let(:customer) { create(:customer, shopify_store: store) }

    def order_with(estimated:, parcel_costs:, name:)
      o = create(:order, customer: customer, shopify_store: store, name: name,
                         estimated_shipping_cost: estimated, ordered_at: 1.day.ago)
      parcel_costs.each_with_index do |c, i|
        create(:parcel, shopify_store: store, order: o, identifier: "#{name}-#{i}", cost_amount: c)
      end
      o
    end

    it "compares actual against estimated only on orders that have BOTH" do
      order_with(estimated: 10, parcel_costs: [ 15 ], name: "PKS#1")          # comparable: +5
      order_with(estimated: 20, parcel_costs: [ 18 ], name: "PKS#2")          # comparable: -2
      order_with(estimated: nil, parcel_costs: [ 99 ], name: "PKS#3")         # actual only — excluded from variance
      create(:order, customer: customer, shopify_store: store, name: "PKS#4",
                     estimated_shipping_cost: 30, ordered_at: 1.day.ago)      # estimate only — excluded

      metrics = described_class.new(company, range_key: "past_7_days").call[:current]

      expect(metrics[:shipping_estimated_total]).to eq(30)   # 10 + 20
      expect(metrics[:shipping_actual_total]).to eq(33)      # 15 + 18
      expect(metrics[:shipping_variance]).to eq(3)
      expect(metrics[:shipping_variance_pct]).to eq(10.0)
    end

    it "counts multi-parcel orders" do
      order_with(estimated: 10, parcel_costs: [ 5, 5, 5 ], name: "PKS#5")
      order_with(estimated: 10, parcel_costs: [ 9 ], name: "PKS#6")

      metrics = described_class.new(company, range_key: "past_7_days").call[:current]

      expect(metrics[:multi_parcel_orders_count]).to eq(1)
    end

    it "returns nil variance_pct when there is nothing comparable" do
      metrics = described_class.new(company, range_key: "past_7_days").call[:current]

      expect(metrics[:shipping_variance_pct]).to be_nil
      expect(metrics[:multi_parcel_orders_count]).to eq(0)
    end
  end
```

- [ ] **Step 2: 執行測試，確認失敗**

Run: `bundle exec rspec spec/services/dashboard_metrics_service_spec.rb -e "shipping variance metrics"`
Expected: FAIL — `expected: 30, got: nil`

- [ ] **Step 3: 擴充 aggregate_shipping**

把 `app/services/dashboard_metrics_service.rb` 的 `aggregate_shipping` 整個換成：

```ruby
  def aggregate_shipping(store_scope, range)
    total = BigDecimal("0")
    count_total = 0
    count_actual = 0
    count_estimated_only = 0

    # Variance is only meaningful on orders that have BOTH figures. Summing all
    # estimates against all actuals would compare two different order sets and
    # produce a number that means nothing.
    comparable_estimated = BigDecimal("0")
    comparable_actual    = BigDecimal("0")
    multi_parcel_orders  = 0

    store_scope.find_each do |store|
      tz = store.active_timezone
      start_utc = tz.local(range.first.year, range.first.month, range.first.day).utc
      end_utc   = tz.local(range.last.year,  range.last.month,  range.last.day).end_of_day.utc

      orders = Order.where(shopify_store_id: store.id, ordered_at: start_utc..end_utc)

      total += orders.sum("COALESCE(actual_shipping_cost, estimated_shipping_cost, 0)")
      count_total          += orders.count
      count_actual         += orders.where.not(actual_shipping_cost: nil).count
      count_estimated_only += orders.where(actual_shipping_cost: nil).where.not(estimated_shipping_cost: nil).count

      comparable = orders.where.not(actual_shipping_cost: nil).where.not(estimated_shipping_cost: nil)
      comparable_estimated += comparable.sum(:estimated_shipping_cost)
      comparable_actual    += comparable.sum(:actual_shipping_cost)

      multi_parcel_orders += Parcel.where(order_id: orders.select(:id))
                                   .group(:order_id)
                                   .having("COUNT(*) > 1")
                                   .count
                                   .size
    end

    variance = comparable_actual - comparable_estimated
    variance_pct = comparable_estimated.positive? ? (variance / comparable_estimated * 100).round(2) : nil

    pct = ->(n) { count_total > 0 ? (n.to_f / count_total * 100).round(1) : nil }
    [
      total,
      {
        coverage:       pct.call(count_actual + count_estimated_only),
        actual:         pct.call(count_actual),
        estimated_only: pct.call(count_estimated_only),
        estimated_total: comparable_estimated,
        actual_total:    comparable_actual,
        variance:        variance,
        variance_pct:    variance_pct,
        multi_parcel_orders: multi_parcel_orders
      }
    ]
  end
```

在 `aggregate_metrics` 回傳的 hash 中，`shipping_coverage_estimated_pct:` 那一行**之後**加入：

```ruby
      shipping_estimated_total: shipping_breakdown[:estimated_total],
      shipping_actual_total: shipping_breakdown[:actual_total],
      shipping_variance: shipping_breakdown[:variance],
      shipping_variance_pct: shipping_breakdown[:variance_pct],
      multi_parcel_orders_count: shipping_breakdown[:multi_parcel_orders]
```

- [ ] **Step 4: 建立 Section partial**

`app/views/dashboard/_shipping_section.html.erb`：

```erb
<section class="mb-8">
  <%= render "dashboard/section_header", title: t("dashboard.section_shipping") %>

  <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
    <%= render "dashboard/metric_card",
        title: t("dashboard.shipping_estimated"),
        value: number_to_currency(metrics[:current][:shipping_estimated_total]),
        previous: metrics[:previous][:shipping_estimated_total],
        current_raw: metrics[:current][:shipping_estimated_total],
        invert_color: true %>

    <%= render "dashboard/metric_card",
        title: t("dashboard.shipping_actual"),
        value: number_to_currency(metrics[:current][:shipping_actual_total]),
        previous: metrics[:previous][:shipping_actual_total],
        current_raw: metrics[:current][:shipping_actual_total],
        invert_color: true %>

    <%= render "dashboard/metric_card",
        title: t("dashboard.shipping_variance"),
        value: metrics[:current][:shipping_variance_pct] ?
                 "#{number_to_currency(metrics[:current][:shipping_variance])} (#{metrics[:current][:shipping_variance_pct]}%)" :
                 "—",
        previous: metrics[:previous][:shipping_variance],
        current_raw: metrics[:current][:shipping_variance],
        invert_color: true %>

    <%= render "dashboard/metric_card",
        title: t("dashboard.multi_parcel_orders"),
        value: number_with_delimiter(metrics[:current][:multi_parcel_orders_count]),
        previous: metrics[:previous][:multi_parcel_orders_count],
        current_raw: metrics[:current][:multi_parcel_orders_count],
        invert_color: true %>
  </div>

  <div class="mt-2 flex items-center justify-between">
    <p class="text-xs text-gray-500">
      <%= t("dashboard.shipping_coverage") %>:
      <%= metrics[:current][:shipping_coverage_actual_pct] || 0 %>%
      <span class="text-gray-400"><%= t("dashboard.shipping_coverage_caveat") %></span>
    </p>

    <%= link_to t("dashboard.view_variance"),
          parcels_path(from_date: metrics[:date_range].first, to_date: metrics[:date_range].last,
                       sort_column: "variance", sort_direction: "desc"),
          class: "text-sm font-medium text-gray-900 hover:underline" %>
  </div>
</section>
```

- [ ] **Step 5: 掛進 dashboard**

`app/views/dashboard/show.html.erb`，在 `<%# ===== Advertising ===== %>` 那一段**之前**插入：

```erb
    <%# ===== Shipping ===== %>
    <%= render "dashboard/shipping_section", metrics: @metrics %>
```

- [ ] **Step 6: i18n**

`zh-TW.yml` 的 `dashboard:` 區塊加入：

```yaml
    section_shipping: "物流"
    shipping_estimated: "預估運費"
    shipping_actual: "實際運費"
    shipping_variance: "運費差異"
    multi_parcel_orders: "多包裹訂單"
    shipping_coverage_caveat: "（覆蓋率越低，差異數字越不可靠）"
    view_variance: "查看差異明細 →"
```

`zh-CN.yml`：

```yaml
    section_shipping: "物流"
    shipping_estimated: "预估运费"
    shipping_actual: "实际运费"
    shipping_variance: "运费差异"
    multi_parcel_orders: "多包裹订单"
    shipping_coverage_caveat: "（覆盖率越低，差异数字越不可靠）"
    view_variance: "查看差异明细 →"
```

`en.yml`：

```yaml
    section_shipping: "Shipping"
    shipping_estimated: "Estimated shipping"
    shipping_actual: "Actual shipping"
    shipping_variance: "Shipping variance"
    multi_parcel_orders: "Multi-parcel orders"
    shipping_coverage_caveat: "(the lower the coverage, the less the variance means)"
    view_variance: "View variance detail →"
```

- [ ] **Step 7: 寫 request spec**

`spec/requests/dashboard_shipping_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe "Dashboard shipping section", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2, timezone: "UTC") }
  let(:customer) { create(:customer, shopify_store: store) }

  before { sign_in user }

  it "renders the shipping section with a link into the variance report" do
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#3052",
                           estimated_shipping_cost: 18.20, ordered_at: 1.day.ago)
    create(:parcel, shopify_store: store, order: order, identifier: "B1", cost_amount: 20)
    create(:parcel, shopify_store: store, order: order, identifier: "B2", cost_amount: 20.10)

    get authenticated_root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("dashboard.section_shipping"))
    expect(response.body).to include(I18n.t("dashboard.view_variance"))
    expect(response.body).to include("sort_column=variance")
  end
end
```

- [ ] **Step 8: 執行測試，確認通過**

Run: `bundle exec rspec spec/services/dashboard_metrics_service_spec.rb spec/requests/dashboard_shipping_spec.rb`
Expected: PASS

- [ ] **Step 9: RuboCop 與 commit**

```bash
bin/rubocop -a app/services/dashboard_metrics_service.rb
git add app/services/dashboard_metrics_service.rb app/views/dashboard config/locales spec/services/dashboard_metrics_service_spec.rb spec/requests/dashboard_shipping_spec.rb
git commit -m "feat(dashboard): shipping section comparing actual vs estimated with variance drill-down"
```

---

### Task 8: System specs（端到端）

**Files:**
- Create: `spec/system/parcel_import_spec.rb`
- Create: `spec/system/parcel_variance_spec.rb`

**Interfaces:**
- Consumes: Task 4–7 的所有 UI

- [ ] **Step 1: 匯入流程 system spec**

`spec/system/parcel_import_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe "Parcel import", type: :system do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let!(:store)  { create(:shopify_store, user: user, company: company, name: "CSFD", cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:order)   { create(:order, customer: customer, shopify_store: store, name: "PKS#3037", estimated_shipping_cost: 20) }

  before { sign_in user }

  it "uploads, previews, confirms and lands the data" do
    path = XlsxBuilder.build(rows: [
      XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.73),
      XlsxBuilder.row(seq: 2, identifier: "XMBDE2012382", order_name: "PKS#9999", cost: 65.57)
    ])

    visit import_parcels_path

    select "CSFD", from: "shopify_store_id"
    attach_file "file", path
    click_button I18n.t("parcels.import.parse")

    # Preview must not have written anything yet
    expect(page).to have_content(I18n.t("parcels.import.preview_title"))
    expect(page).to have_content("2")
    expect(page).to have_content("XMBDE2012382")   # the unmatched one is called out
    expect(Parcel.count).to eq(0)

    click_button I18n.t("parcels.import.confirm")

    expect(page).to have_content(I18n.t("parcels.import.done", count: 2))
    expect(Parcel.count).to eq(2)
    expect(order.reload.actual_shipping_cost).to eq(33.30)
  end

  it "blocks the import when the store has no fx rate" do
    store.update!(cost_fx_rate: nil)
    path = XlsxBuilder.build(rows: [ XlsxBuilder.row(seq: 1, identifier: "X1", order_name: "PKS#3037") ])

    visit import_parcels_path
    select "CSFD", from: "shopify_store_id"
    attach_file "file", path
    click_button I18n.t("parcels.import.parse")

    expect(page).to have_content("CSFD")
    expect(Parcel.count).to eq(0)
  end
end
```

- [ ] **Step 2: 差異報表 system spec**

`spec/system/parcel_variance_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe "Shipping variance report", type: :system do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let!(:store)  { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2, timezone: "UTC") }
  let(:customer) { create(:customer, shopify_store: store) }

  let!(:blown) do
    o = create(:order, customer: customer, shopify_store: store, name: "PKS#3052",
                       estimated_shipping_cost: 18.20, ordered_at: 1.day.ago)
    create(:parcel, shopify_store: store, order: o, identifier: "B1", cost_cny: 144, cost_amount: 20)
    create(:parcel, shopify_store: store, order: o, identifier: "B2", cost_cny: 144.72, cost_amount: 20.10)
    o
  end

  before { sign_in user }

  it "navigates from the dashboard into the variance report" do
    visit authenticated_root_path
    click_link I18n.t("dashboard.view_variance")

    expect(page).to have_content(I18n.t("parcels.title"))
    expect(page).to have_content("PKS#3052")
    expect(page).to have_content("B1")
    expect(page).to have_content("B2")
  end

  it "edits a parcel cost inline and re-rolls up the order" do
    visit parcels_path

    within("##{ActionView::RecordIdentifier.dom_id(blown.parcels.order(:identifier).first)}") do
      fill_in I18n.t("parcels.columns.cost_cny"), with: "72.00"
      click_button I18n.t("parcels.save")
    end

    expect(page).to have_content("10")   # 72 / 7.2
    expect(blown.reload.actual_shipping_cost).to eq(30.10)
  end

  it "assigns an unmatched parcel to an order" do
    create(:parcel, shopify_store: store, order: nil, identifier: "ORPHAN1", cost_amount: 5)

    visit parcels_path(tab: "unmatched")
    expect(page).to have_content("ORPHAN1")

    select "PKS#3052", from: "parcel[order_id]"
    click_button I18n.t("parcels.assign")

    expect(Parcel.find_by(identifier: "ORPHAN1").order_id).to eq(blown.id)
    expect(blown.reload.actual_shipping_cost).to eq(45.10)   # 20 + 20.10 + 5
  end
end
```

- [ ] **Step 3: 執行 system specs**

Run: `bundle exec rspec spec/system/parcel_import_spec.rb spec/system/parcel_variance_spec.rb`
Expected: PASS

- [ ] **Step 4: 全套測試 + 覆蓋率**

Run: `bundle exec rspec`
Expected: 全綠，且覆蓋率報告 ≥ 95%。若低於 95%，補測未覆蓋的分支（`coverage/index.html` 可看出漏掉哪些行）。

- [ ] **Step 5: 安全與靜態檢查**

```bash
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
```

Expected: 三者皆無 offense / warning。`roo` 若被 bundler-audit 標記，升級到無漏洞版本。

- [ ] **Step 6: Commit 與開 PR**

```bash
git add spec/system
git commit -m "test(shipping): end-to-end specs for bill import, variance report and inline edit"
git push -u origin feature/actual-shipping-cost-variance
gh pr create --base staging --title "feat: actual per-parcel shipping cost + variance report" --body "$(cat <<'EOF'
## Summary
補上 `orders.actual_shipping_cost` 的寫入路徑（該欄位自 2026-05-31 起就預留但從未被填入），並在其上建立實際 vs 預估的差異比較報表。

- 新增 `parcels` 表，唯一鍵為店小秘「订单编号」，支援一單多包與補發件（R1 後綴）
- Excel 帳單匯入，含預覽確認關卡（owner-only、覆蓋式、自動略過檔案底部的合計行）
- Company 層級的 agent API key + Parcel CRUD API（POST 為 upsert，與 Excel 匯入共用 `ParcelUpserter`）
- 訂單維度的差異報表，可展開看 parcel 費用拆解（挂号费/操作费被收了幾次）
- Dashboard 物流 Section：預估 vs 實際、差異、覆蓋率、多包裹訂單數，可跳轉查因

設計文件：`docs/superpowers/specs/2026-07-14-actual-shipping-cost-variance-design.md`

## Test plan
- [x] Model spec：rollup（含 parcel 跨訂單搬移時雙邊重算、最後一個 parcel 刪除後回 nil）
- [x] Service spec：parser 排除合計行、upserter 冪等
- [x] Request spec：權限、API CRUD、Company key 與 EmailAccount key 認證隔離
- [x] System spec：上傳→預覽→確認、inline edit、未配對指派、Dashboard 跳轉
- [x] 以真實 6 月帳單驗證 parser：482 筆、0 錯誤、總額 58,578.98 CNY

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

**Spec coverage 對照：**

| Spec 章節 | 對應 Task |
|---|---|
| §3.1 parcels 表 | Task 1 |
| §3.2 匯率快照 | Task 1（欄位）、Task 3（換算邏輯） |
| §3.3 Rollup | Task 1 |
| §4.1 Parser / Upserter | Task 2、Task 3 |
| §4.2 預覽確認流程 | Task 4 |
| §4.3 roo 依賴 | Task 2 Step 1 |
| §5 Index 差異報表 | Task 5 |
| §6 API | Task 6 |
| §7 Dashboard Section | Task 7 |
| §8 權限 | Task 4 Step 1（permission key）、Task 4/5/6（owner-only） |
| §9 測試策略 | 每個 Task 內含，Task 8 收尾 |

**已知的實作風險（執行時要注意）：**

1. **Solid Cache 的 `max_entry_size`** —— 482 行序列化約 200KB。若 Task 4 的 preview 在真實檔案上寫入 cache 失敗，改為把上傳檔存到 `Rails.root/tmp/parcel_imports/<token>.xlsx`，cache 只存路徑，confirm 時重新解析並刪檔（單容器可行；多容器需改用 DB 暫存表）。
2. **`roo` 讀取日期欄位** 可能回傳 `Date` 而非 `Time`，`ParcelBillParser#cast` 已同時處理 String 與非 String，但實際跑真實檔案時（Task 2 Step 7）要確認 `shipped_at` 有值。
3. **request spec 的 `assigns_summary`** helper 依賴 controller 實例，若 RSpec 版本不支援，改為斷言 `response.body` 內容（Task 4 Step 8 已註明退路）。
