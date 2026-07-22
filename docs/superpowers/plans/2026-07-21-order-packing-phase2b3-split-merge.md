# 訂單打包 Phase 2B-3 — 折包（拆分）+ 合併 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓 `pending_process` 包裹能被拆成多個子包裹（同款商品可分箱），並能合併回一個；折包狀態下 Shopify 自動同步凍結，合併後自動恢復。

**Architecture:** 扁平兄弟包裹（同 `order_id` 關聯，各自新 `number`），兩個 service（`PackageSplitter` / `PackageMerger`）承載重組邏輯，`PackageAutoBuilder` 依「該訂單包裹數」三分支路由（0 建包 / 1 同步 / >1 凍結）。UI 沿用 Modal + `dom_id` + 局部 `turbo_stream` replace + Stimulus。

**Tech Stack:** Rails 8.1、AASM、Hotwire（Turbo + Stimulus）、Importmap、Tailwind、PostgreSQL(UUID)、RSpec + FactoryBot。

## Global Constraints

- 所有 table id 用 UUID（gen_random_uuid）。
- 測試：RSpec + FactoryBot，**無 mock、打真 DB、95%+ line coverage**；每功能 model/service + request + system。
- 絕不 commit 到 `staging` / `main`；在 `feature/order-packing-phase2b3` 上做。推送用 `git push -u origin feature/order-packing-phase2b3`（勿裸 `git push`）。
- 齊全檢查 gate 只在 2C 的 apply_tracking，**折包/合併本身不設齊全 gate**。
- 權限 gate：折包/合併屬「處理」→ `current_membership&.package_process?`；每個寫入 action 先 `set_package`（`scoped_packages.find` → 跨公司 404）再過權限。失敗一律 422 / redirect，**絕不 500**。
- Ruby toolchain：跑 rspec/rails 前，PATH 前置 `/home/simon/.rubies/ruby-3.4.7/bin`。單檔 rspec 因 SimpleCov 可能 exit 2，屬預期。
- 溝通與說明用繁體中文；程式碼/路徑/commit 訊息用英文。

---

## File Structure

- **Migration** `db/migrate/*_change_packages_order_id_index_non_unique.rb`（新增）— 拿掉 `order_id` 唯一索引，改非唯一。
- **`app/models/package.rb`**（改）— 加 `order_packages` / `split?`。
- **`app/services/package_auto_builder.rb`**（改）— `do_call` 三分支凍結。
- **`app/services/package_splitter.rb`**（新增）— 折包重組 + 驗證。
- **`app/services/package_merger.rb`**（新增）— 合併塌回 + 衝突偵測。
- **`app/controllers/packages_controller.rb`**（改）— `split` / `merge` action + params 解析。
- **`config/routes.rb`**（改）— member `post :split` / `post :merge`。
- **Views**（新增）：`_siblings_strip.html.erb`、`_split_dialog.html.erb`、`split.turbo_stream.erb`、`merge.turbo_stream.erb`；**`_modal.html.erb`**（改，插入 strip + dialog，接受 optional `split_errors`）。
- **`app/javascript/controllers/split_controller.js`**（新增）— 對話框開關、動態加/移除包裹欄、即時餘數/小計/驗證。
- **i18n** `config/locales/{en,zh-TW,zh-CN}.yml`（改）— 新 keys。
- **Specs**：`spec/services/package_splitter_spec.rb`、`spec/services/package_merger_spec.rb`（新增）、`spec/services/package_auto_builder_spec.rb`（改）、`spec/models/package_spec.rb`（改）、`spec/requests/packages_spec.rb`（改）、`spec/system/packages_spec.rb`（改）。

**共用測試前置**（各 spec 內沿用現有慣例）：

```ruby
let(:user)     { create(:user) }
let(:company)  { user.companies.first }
let(:store)    { create(:shopify_store, user: user, company: company, packing_enabled: true,
                        package_prefix: "XMBDE", package_number_start: 2013094).tap { |s|
                        s.update_columns(packing_enabled_at: 1.year.ago) } }
let(:customer) { create(:customer, shopify_store: store) }
```

---

### Task 1: Migration — 一訂單多包裹（拿掉 order_id 唯一索引）

**Files:**
- Create: `db/migrate/YYYYMMDDHHMMSS_change_packages_order_id_index_non_unique.rb`
- Modify: `db/schema.rb`（由 migrate 產生）
- Test: `spec/models/package_spec.rb`

**Interfaces:**
- Produces: `packages` 可同 `order_id` 多列；`index_packages_on_order_id`（非唯一）。

- [ ] **Step 1: Write the failing test**

在 `spec/models/package_spec.rb` 內新增（用上方共用前置）：

```ruby
describe "one order → many packages" do
  it "allows two packages to share the same order_id" do
    order = create(:order, customer: customer, shopify_store: store)
    create(:package, shopify_store: store, order: order, number: 1)
    second = build(:package, shopify_store: store, order: order, number: 2)
    expect(second.save).to be(true)
    expect(store.packages.where(order_id: order.id).count).to eq(2)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/package_spec.rb -e "share the same order_id"`
Expected: FAIL — `ActiveRecord::RecordNotUnique`（違反 `index_packages_on_order_id_unique`）。

- [ ] **Step 3: Write the migration**

`db/migrate/YYYYMMDDHHMMSS_change_packages_order_id_index_non_unique.rb`（用實際時間戳；可 `bin/rails g migration ChangePackagesOrderIdIndexNonUnique` 生檔後貼入）：

```ruby
class ChangePackagesOrderIdIndexNonUnique < ActiveRecord::Migration[8.1]
  def up
    remove_index :packages, name: "index_packages_on_order_id_unique"
    add_index :packages, :order_id, name: "index_packages_on_order_id"
  end

  def down
    remove_index :packages, name: "index_packages_on_order_id"
    add_index :packages, :order_id, unique: true, name: "index_packages_on_order_id_unique"
  end
end
```

- [ ] **Step 4: Migrate and run the test**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bundle exec rspec spec/models/package_spec.rb -e "share the same order_id"`
Expected: PASS。確認 `db/schema.rb` 內 `packages` 的 order_id 索引已變成非唯一 `index_packages_on_order_id`。

- [ ] **Step 5: Commit**

```bash
git add db/migrate db/schema.rb spec/models/package_spec.rb
git commit -m "feat(packing): allow one order to have many packages (drop order_id unique index)"
```

---

### Task 2: Package 關聯輔助 + Auto-builder 三分支凍結

**Files:**
- Modify: `app/models/package.rb`
- Modify: `app/services/package_auto_builder.rb:24-42`（`do_call`）
- Test: `spec/models/package_spec.rb`, `spec/services/package_auto_builder_spec.rb`

**Interfaces:**
- Produces:
  - `Package#order_packages` → `ActiveRecord::Relation`（同 `shopify_store` + `order_id`，`order(:number)`）。
  - `Package#split?` → `Boolean`（`order_packages.count > 1`）。
  - `PackageAutoBuilder#do_call` 對 `count > 1` 的訂單早退（凍結，含全退）。

- [ ] **Step 1: Write the failing model test**

在 `spec/models/package_spec.rb` 新增：

```ruby
describe "#order_packages / #split?" do
  it "reports split? true when the order has more than one package" do
    order = create(:order, customer: customer, shopify_store: store)
    a = create(:package, shopify_store: store, order: order, number: 1)
    create(:package, shopify_store: store, order: order, number: 2)
    expect(a.order_packages.count).to eq(2)
    expect(a.split?).to be(true)
  end

  it "reports split? false for a lone package" do
    order = create(:order, customer: customer, shopify_store: store)
    a = create(:package, shopify_store: store, order: order, number: 1)
    expect(a.split?).to be(false)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/models/package_spec.rb -e "order_packages"`
Expected: FAIL — `NoMethodError: undefined method 'order_packages'`。

- [ ] **Step 3: Add the model methods**

在 `app/models/package.rb`（`order_cancelled?` 之後、`end` 之前）加入：

```ruby
  # All packages of this package's order (siblings included), lowest number
  # first. Used by the split/merge UI to group and navigate boxes of one order.
  def order_packages
    shopify_store.packages.where(order_id: order_id).order(:number)
  end

  # True while the order is folded into multiple boxes. Auto-sync is frozen in
  # this state (see PackageAutoBuilder#do_call); merging back to one resumes it.
  def split?
    order_packages.count > 1
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/models/package_spec.rb -e "order_packages"`
Expected: PASS。

- [ ] **Step 5: Write the failing auto-builder tests**

在 `spec/services/package_auto_builder_spec.rb` 新增（沿用該檔既有 `let(:store)` / `let(:order)`）：

```ruby
describe "frozen while split (order has >1 package)" do
  it "does NOT smart_update any package when the order is split into multiple" do
    described_class.new(order).call # builds package #1 (pending_review)
    p1 = store.packages.find_by(order: order)
    p1.update!(aasm_state: "pending_process")
    p2 = store.packages.create!(order: order, number: 9_000_001, aasm_state: "pending_process",
                                shipping_address_snapshot: { "city" => "Original" })

    order.update!(shopify_data: { "shipping_address" => { "city" => "Changed" } })
    described_class.new(order.reload).call

    expect(p1.reload.shipping_address_snapshot["city"]).to be_nil
    expect(p2.reload.shipping_address_snapshot["city"]).to eq("Original")
  end

  it "does NOT refund sub-packages when a split order is fully refunded" do
    described_class.new(order).call
    p1 = store.packages.find_by(order: order)
    p1.update!(aasm_state: "pending_process")
    store.packages.create!(order: order, number: 9_000_002, aasm_state: "pending_process")

    order.update!(financial_status: "refunded")
    described_class.new(order.reload).call

    expect(store.packages.where(order_id: order.id).pluck(:aasm_state)).to all(eq("pending_process"))
  end

  it "resumes smart_update once merged back to a single package" do
    described_class.new(order).call
    p1 = store.packages.find_by(order: order)
    order.update!(shopify_data: { "shipping_address" => { "city" => "Resumed" } })
    described_class.new(order.reload).call # count == 1 → smart_update runs
    expect(p1.reload.shipping_address_snapshot["city"]).to eq("Resumed")
  end
end
```

- [ ] **Step 6: Run to verify they fail**

Run: `bundle exec rspec spec/services/package_auto_builder_spec.rb -e "frozen while split"`
Expected: FAIL（目前 `find_by` 會對其中一個 package 做 smart_update / 或 refund）。

- [ ] **Step 7: Rewrite `do_call`**

把 `app/services/package_auto_builder.rb` 的 `do_call` 換成：

```ruby
  # Routes by how many packages the order currently has:
  #   >1  → frozen (split state): manual reorg only, no auto sync/refund.
  #   1   → smart_update the lone package (honoring override flags), or refund it.
  #   0   → build a new package if eligible.
  # Merging a split order back to one package (count → 1) resumes auto-sync.
  def do_call
    return unless @store

    packages = @store.packages.where(order_id: @order.id)
    count = packages.count

    return if count > 1 # frozen — see design doc Q1 (split state)

    if fully_refunded?
      existing = packages.first
      refund(existing) if existing
      return
    end

    if count == 1
      existing = packages.first
      smart_update(existing) unless existing.refunded?
      return
    end

    return unless @store.packing_enabled?
    return unless eligible?

    build_package
  end
```

- [ ] **Step 8: Run the full auto-builder spec**

Run: `bundle exec rspec spec/services/package_auto_builder_spec.rb`
Expected: PASS（新測試 + 既有全綠；既有測試都是 count 0/1 情境，行為不變）。

- [ ] **Step 9: Commit**

```bash
git add app/models/package.rb app/services/package_auto_builder.rb spec/models/package_spec.rb spec/services/package_auto_builder_spec.rb
git commit -m "feat(packing): freeze auto-builder while an order is split; add order_packages/split? helpers"
```

---

### Task 3: `PackageSplitter` service

**Files:**
- Create: `app/services/package_splitter.rb`
- Test: `spec/services/package_splitter_spec.rb`

**Interfaces:**
- Consumes: `Package`（來源，須 `pending_process`）、`store.package_number_seq` / `#package_number_start`。
- Produces:
  - `PackageSplitter.new(source_package, allocations).call` → `PackageSplitter::Result`。
  - `allocations`：`{ order_line_item_id(String) => [Integer, ...] }`，陣列每格 = 新包裹（包裹2..N，**不含**來源餘數包裹1）的分配數；所有陣列等長 = 新箱數。
  - `Result`：`Struct` with `success?`(Boolean)、`source`(Package)、`new_packages`(Array<Package>)、`errors`(Array<Symbol>)。
  - 錯誤符號：`:empty`, `:ragged`, `:unknown_item`, `:negative`, `:over_allocated`, `:empty_box`, `:empty_source`。

- [ ] **Step 1: Write the failing tests**

`spec/services/package_splitter_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe PackageSplitter do
  let(:user)     { create(:user) }
  let(:company)  { user.companies.first }
  let(:store)    { create(:shopify_store, user: user, company: company, packing_enabled: true,
                          package_prefix: "XMBDE", package_number_start: 2013094).tap { |s|
                          s.update_columns(packing_enabled_at: 1.year.ago) } }
  let(:customer) { create(:customer, shopify_store: store) }
  let(:order)    { create(:order, customer: customer, shopify_store: store) }
  let(:oli_a)    { create(:order_line_item, order: order) }
  let(:oli_b)    { create(:order_line_item, order: order) }

  let(:source) do
    pkg = create(:package, shopify_store: store, order: order, number: 100,
                 aasm_state: "pending_process", logistics_channel_id: nil,
                 shipping_address_snapshot: { "name" => "Amy", "city" => "Paris" }, address_overridden: true)
    create(:package_item, package: pkg, order_line_item: oli_a, sku: "A", title: "Art A",
           quantity: 3, refunded_quantity: 0, customs_name_zh: "畫", customs_overridden: true)
    create(:package_item, package: pkg, order_line_item: oli_b, sku: "B", title: "Art B",
           quantity: 2, refunded_quantity: 0)
    pkg
  end

  before { store.update_columns(package_number_seq: 2013094) }

  it "carves one new box, moving allocated units and leaving the remainder on the source" do
    result = described_class.new(source, { oli_a.id => [ 1 ], oli_b.id => [ 2 ] }).call

    expect(result.success?).to be(true)
    expect(result.new_packages.size).to eq(1)
    box = result.new_packages.first
    expect(box.aasm_state).to eq("pending_process")
    expect(box.number).to eq(2013094)
    expect(store.reload.package_number_seq).to eq(2013095)
    # new box items
    expect(box.package_items.pluck(:sku, :quantity)).to contain_exactly([ "A", 1 ], [ "B", 2 ])
    # source remainder: A 3→2, B fully moved (2→0) so its source item is deleted
    expect(source.reload.package_items.pluck(:sku, :quantity)).to contain_exactly([ "A", 2 ])
  end

  it "inherits address+override, logistics, and per-item customs+override onto the new box" do
    source.update!(logistics_channel_id: nil)
    box = described_class.new(source, { oli_a.id => [ 1 ], oli_b.id => [ 0 ] }).call.new_packages.first
    expect(box.shipping_address_snapshot).to eq("name" => "Amy", "city" => "Paris")
    expect(box.address_overridden).to be(true)
    a_item = box.package_items.find_by(sku: "A")
    expect(a_item.customs_name_zh).to eq("畫")
    expect(a_item.customs_overridden).to be(true)
  end

  it "keeps the quantity/refunded invariants: only shippable units move, refunded stay on source" do
    source.package_items.find_by(sku: "A").update!(quantity: 3, refunded_quantity: 1) # shippable = 2
    box = described_class.new(source, { oli_a.id => [ 2 ], oli_b.id => [ 0 ] }).call.new_packages.first
    expect(box.package_items.find_by(sku: "A").attributes.values_at("quantity", "refunded_quantity")).to eq([ 2, 0 ])
    # source A: quantity 3 - 2 moved = 1 (the single refunded unit), refunded_quantity unchanged
    src_a = source.reload.package_items.find_by(sku: "A")
    expect([ src_a.quantity, src_a.refunded_quantity ]).to eq([ 1, 1 ])
  end

  it "supports multiple new boxes in one call" do
    result = described_class.new(source, { oli_a.id => [ 1, 1 ], oli_b.id => [ 0, 1 ] }).call
    expect(result.success?).to be(true)
    expect(result.new_packages.size).to eq(2)
    expect(result.new_packages.map(&:number)).to eq([ 2013094, 2013095 ])
    expect(source.reload.package_items.pluck(:sku, :quantity)).to contain_exactly([ "A", 1 ])
  end

  describe "validation (no persistence on failure)" do
    it "rejects an empty box (a box receiving 0 total units)" do
      result = described_class.new(source, { oli_a.id => [ 0 ], oli_b.id => [ 0 ] }).call
      expect(result.success?).to be(false)
      expect(result.errors).to include(:empty_box)
      expect(store.packages.where(order_id: order.id).count).to eq(1)
    end

    it "rejects when the source would keep no shippable units (empty source)" do
      result = described_class.new(source, { oli_a.id => [ 3 ], oli_b.id => [ 2 ] }).call
      expect(result.errors).to include(:empty_source)
    end

    it "rejects over-allocation beyond an item's shippable quantity" do
      result = described_class.new(source, { oli_a.id => [ 4 ], oli_b.id => [ 0 ] }).call
      expect(result.errors).to include(:over_allocated)
    end

    it "rejects negative units" do
      result = described_class.new(source, { oli_a.id => [ -1 ], oli_b.id => [ 2 ] }).call
      expect(result.errors).to include(:negative)
    end

    it "rejects ragged allocation arrays (uneven box counts)" do
      result = described_class.new(source, { oli_a.id => [ 1, 0 ], oli_b.id => [ 1 ] }).call
      expect(result.errors).to include(:ragged)
    end

    it "rejects an unknown line item id" do
      result = described_class.new(source, { "not-a-real-id" => [ 1 ] }).call
      expect(result.errors).to include(:unknown_item)
    end

    it "rejects empty allocations" do
      expect(described_class.new(source, {}).call.errors).to include(:empty)
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/services/package_splitter_spec.rb`
Expected: FAIL — `uninitialized constant PackageSplitter`。

- [ ] **Step 3: Implement the service**

`app/services/package_splitter.rb`：

```ruby
# Folds a pending_process package into one or more new sibling packages
# (same order, new store sequence numbers). Only shippable units
# (quantity - refunded_quantity) move; refunded units stay on the source.
# See docs/superpowers/specs/2026-07-21-order-packing-phase2b3-split-merge-design.md.
class PackageSplitter
  Result = Struct.new(:success?, :source, :new_packages, :errors, keyword_init: true)

  # allocations: { order_line_item_id(String) => [units_for_new_box_1, ...] }
  def initialize(source, allocations)
    @source = source
    @store  = source.shopify_store
    @allocations = (allocations || {}).transform_values { |a| Array(a).map(&:to_i) }
  end

  def call
    errors = validate
    return failure(errors) if errors.any?

    new_packages = []
    @store.with_lock do
      box_count.times do |box_idx|
        pkg = build_box(box_idx)
        new_packages << pkg if pkg
      end
      apply_source_remainders
    end
    Result.new(success?: true, source: @source, new_packages: new_packages, errors: [])
  end

  private

  def failure(errors)
    Result.new(success?: false, source: @source, new_packages: [], errors: errors)
  end

  def source_items_by_li
    @source_items_by_li ||= @source.package_items.index_by { |it| it.order_line_item_id.to_s }
  end

  def box_count
    @box_count ||= @allocations.values.map(&:size).max.to_i
  end

  def shippable(item)
    item.quantity - item.refunded_quantity
  end

  def units_for(item, box_idx)
    (@allocations[item.order_line_item_id.to_s] || [])[box_idx].to_i
  end

  def moved_total(item)
    Array(@allocations[item.order_line_item_id.to_s]).sum
  end

  def validate
    return [ :empty ] if @allocations.empty? || box_count.zero?

    errors = []
    errors << :ragged if @allocations.values.any? { |a| a.size != box_count }
    errors << :unknown_item if @allocations.keys.any? { |k| source_items_by_li[k].nil? }
    errors << :negative if @allocations.values.flatten.any?(&:negative?)
    return errors.uniq if errors.any? # further checks assume well-formed input

    source_items_by_li.each_value do |item|
      errors << :over_allocated if moved_total(item) > shippable(item)
    end

    box_count.times do |box_idx|
      box_units = source_items_by_li.each_value.sum { |it| units_for(it, box_idx) }
      errors << :empty_box if box_units.zero?
    end

    source_remaining = source_items_by_li.each_value.sum { |it| shippable(it) - moved_total(it) }
    errors << :empty_source if source_remaining <= 0

    errors.uniq
  end

  def build_box(box_idx)
    items = source_items_by_li.each_value.select { |it| units_for(it, box_idx).positive? }
    return nil if items.empty?

    seq = @store.package_number_seq || @store.package_number_start
    @store.update!(package_number_seq: seq + 1)
    box = @store.packages.create!(
      order: @source.order,
      number: seq,
      aasm_state: "pending_process",
      shipping_address_snapshot: @source.shipping_address_snapshot,
      address_overridden: @source.address_overridden,
      logistics_channel_id: @source.logistics_channel_id
    )
    items.each do |it|
      box.package_items.create!(
        order_line_item_id: it.order_line_item_id,
        product_variant_id: it.product_variant_id,
        sku: it.sku,
        title: it.title,
        quantity: units_for(it, box_idx),
        refunded_quantity: 0,
        customs_name_zh: it.customs_name_zh,
        customs_name_en: it.customs_name_en,
        declared_value_usd: it.declared_value_usd,
        customs_weight_grams: it.customs_weight_grams,
        hs_code: it.hs_code,
        import_hs_code: it.import_hs_code,
        customs_overridden: it.customs_overridden
      )
    end
    box
  end

  def apply_source_remainders
    source_items_by_li.each_value do |item|
      moved = moved_total(item)
      next if moved.zero?

      new_qty = item.quantity - moved
      new_qty.zero? ? item.destroy! : item.update!(quantity: new_qty)
    end
  end
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rspec spec/services/package_splitter_spec.rb`
Expected: PASS（全綠）。

- [ ] **Step 5: Commit**

```bash
git add app/services/package_splitter.rb spec/services/package_splitter_spec.rb
git commit -m "feat(packing): add PackageSplitter service (fold a package into sibling boxes)"
```

---

### Task 4: `PackageMerger` service

**Files:**
- Create: `app/services/package_merger.rb`
- Test: `spec/services/package_merger_spec.rb`

**Interfaces:**
- Consumes: `Package` 或 `Order`；同訂單 `pending_process` 兄弟包裹。
- Produces:
  - `PackageMerger.new(package_or_order)` 具 `#call` → `Package`（存活者，號碼最小）、`#conflict?` → `Boolean`（兄弟間地址快照或 `logistics_channel_id` 不一致）、`#pending_siblings` → `Array<Package>`。

- [ ] **Step 1: Write the failing tests**

`spec/services/package_merger_spec.rb`：

```ruby
require "rails_helper"

RSpec.describe PackageMerger do
  let(:user)     { create(:user) }
  let(:company)  { user.companies.first }
  let(:store)    { create(:shopify_store, user: user, company: company) }
  let(:customer) { create(:customer, shopify_store: store) }
  let(:order)    { create(:order, customer: customer, shopify_store: store) }
  let(:oli_a)    { create(:order_line_item, order: order) }

  def box(number, addr: { "city" => "Paris" }, channel_id: nil)
    create(:package, shopify_store: store, order: order, number: number,
           aasm_state: "pending_process", shipping_address_snapshot: addr,
           logistics_channel_id: channel_id)
  end

  it "collapses siblings into the lowest-numbered survivor, summing items by line item" do
    survivor = box(10)
    create(:package_item, package: survivor, order_line_item: oli_a, sku: "A", quantity: 2, refunded_quantity: 1)
    other = box(11)
    create(:package_item, package: other, order_line_item: oli_a, sku: "A", quantity: 3, refunded_quantity: 0)

    result = described_class.new(survivor).call

    expect(result).to eq(survivor)
    expect(store.packages.where(order_id: order.id).count).to eq(1)
    item = survivor.reload.package_items.find_by(order_line_item_id: oli_a.id)
    expect([ item.quantity, item.refunded_quantity ]).to eq([ 5, 1 ]) # 2+3, 1+0
  end

  it "moves a line item that the survivor lacks, then destroys the absorbed package" do
    survivor = box(10)
    other = box(11)
    oli_b = create(:order_line_item, order: order)
    create(:package_item, package: other, order_line_item: oli_b, sku: "B", quantity: 4)

    described_class.new(order).call

    expect(store.packages.where(order_id: order.id).count).to eq(1)
    expect(survivor.reload.package_items.pluck(:sku, :quantity)).to contain_exactly([ "B", 4 ])
  end

  it "keeps the survivor's package-level fields, discarding absorbed ones" do
    channel = create(:logistics_channel)
    survivor = box(10, addr: { "city" => "Survivor" }, channel_id: channel.id)
    box(11, addr: { "city" => "Absorbed" }, channel_id: nil)
    described_class.new(survivor).call
    expect(survivor.reload.shipping_address_snapshot).to eq("city" => "Survivor")
    expect(survivor.logistics_channel_id).to eq(channel.id)
  end

  describe "#conflict?" do
    it "is true when siblings differ on address or logistics" do
      s = box(10, addr: { "city" => "Paris" })
      box(11, addr: { "city" => "Lyon" })
      expect(described_class.new(s).conflict?).to be(true)
    end

    it "is false when siblings agree" do
      s = box(10, addr: { "city" => "Paris" })
      box(11, addr: { "city" => "Paris" })
      expect(described_class.new(s).conflict?).to be(false)
    end

    it "is false for a lone package (nothing to merge)" do
      expect(described_class.new(box(10)).conflict?).to be(false)
    end
  end

  it "only merges pending_process siblings, leaving a held sibling untouched" do
    survivor = box(10)
    held = box(11)
    held.update!(aasm_state: "held", held_from: "pending_process")
    described_class.new(survivor).call
    expect(store.packages.where(order_id: order.id).pluck(:aasm_state)).to contain_exactly("pending_process", "held")
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/services/package_merger_spec.rb`
Expected: FAIL — `uninitialized constant PackageMerger`。

- [ ] **Step 3: Implement the service**

`app/services/package_merger.rb`：

```ruby
# Collapses a split order's pending_process sibling packages back into the
# lowest-numbered one (the original). Items are summed by order_line_item_id;
# package-level fields (address/logistics/note/customs) are the survivor's.
# See docs/superpowers/specs/2026-07-21-order-packing-phase2b3-split-merge-design.md.
class PackageMerger
  def initialize(package_or_order)
    @order = package_or_order.is_a?(Package) ? package_or_order.order : package_or_order
    @store = @order.shopify_store
  end

  def pending_siblings
    @store.packages.where(order_id: @order.id, aasm_state: "pending_process").order(:number).to_a
  end

  # True when the boxes to be merged disagree on address or logistics channel —
  # the UI warns before discarding the non-survivor values.
  def conflict?
    boxes = pending_siblings
    return false if boxes.size < 2

    boxes.map(&:shipping_address_snapshot).uniq.size > 1 ||
      boxes.map(&:logistics_channel_id).uniq.size > 1
  end

  # Returns the survivor package. A no-op (returns the lone box) when there is
  # nothing to merge.
  def call
    boxes = pending_siblings
    survivor = boxes.first
    return survivor if boxes.size < 2

    survivor.with_lock do
      boxes.drop(1).each { |box| absorb(box, survivor) }
    end
    survivor
  end

  private

  def absorb(box, survivor)
    box.package_items.to_a.each do |item|
      existing = survivor.package_items.find { |s| s.order_line_item_id == item.order_line_item_id }
      if existing
        existing.update!(
          quantity: existing.quantity + item.quantity,
          refunded_quantity: existing.refunded_quantity + item.refunded_quantity
        )
      else
        item.update!(package_id: survivor.id)
      end
    end
    box.reload.destroy!
  end
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rspec spec/services/package_merger_spec.rb`
Expected: PASS。（注意：`absorb` 用 `find` 記憶體比對，`survivor.package_items` 需在 `with_lock` 前後為同一集合；若加總後仍讀到舊值，改 `survivor.package_items.reload`。）

- [ ] **Step 5: Commit**

```bash
git add app/services/package_merger.rb spec/services/package_merger_spec.rb
git commit -m "feat(packing): add PackageMerger service (collapse split order back into survivor)"
```

---

### Task 5: Controller `split` / `merge` actions + routes

**Files:**
- Modify: `config/routes.rb:81-90`
- Modify: `app/controllers/packages_controller.rb`
- Create: `app/views/packages/split.turbo_stream.erb`
- Create: `app/views/packages/merge.turbo_stream.erb`
- Test: `spec/requests/packages_spec.rb`

**Interfaces:**
- Consumes: `PackageSplitter`, `PackageMerger`。
- Produces: `POST /packages/:id/split`（`split_package_path`）、`POST /packages/:id/merge`（`merge_package_path`）。`split` 讀 `params[:allocations]`（`{ li_id => [n,...] }`）。失敗 422，成功 turbo_stream。

- [ ] **Step 1: Write the failing request tests**

在 `spec/requests/packages_spec.rb` 新增（沿用該檔 `store` / `customer` / `sign_in user`；owner 預設有權限）：

```ruby
describe "POST /packages/:id/split" do
  let(:order) { create(:order, customer: customer, shopify_store: store, name: "PKS#SPLIT") }
  let(:oli)   { create(:order_line_item, order: order) }
  let!(:src) do
    pkg = create(:package, shopify_store: store, order: order, number: 500, aasm_state: "pending_process")
    create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 3)
    pkg
  end

  it "splits into a new sibling box and returns turbo_stream" do
    post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }
    expect(response).to have_http_status(:ok)
    expect(store.packages.where(order_id: order.id).count).to eq(2)
  end

  it "returns 422 (not 500) on an invalid allocation and persists nothing" do
    post split_package_path(id: src.id), params: { allocations: { oli.id => [ "0" ] } },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(store.packages.where(order_id: order.id).count).to eq(1)
  end

  it "rejects splitting a non-pending_process package" do
    src.update!(aasm_state: "pending_review")
    post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } }
    expect(response).to have_http_status(:found) # redirect with alert
    expect(store.packages.where(order_id: order.id).count).to eq(1)
  end

  it "forbids a member without package_process permission" do
    other = create(:user)
    membership = other.memberships.first || create(:membership, user: other, company: company)
    membership.update!(role: :member, permissions: [ "package_review" ])
    create(:membership, user: other, company: company) if other.memberships.empty?
    sign_in other
    post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } }
    expect(response).to have_http_status(:found)
    expect(store.packages.where(order_id: order.id).count).to eq(1)
  end

  it "404s for a package of another company" do
    stranger = create(:user)
    sign_in stranger
    post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } }
    expect(response).to have_http_status(:not_found)
  end
end

describe "POST /packages/:id/merge" do
  let(:order) { create(:order, customer: customer, shopify_store: store, name: "PKS#MERGE") }
  let(:oli)   { create(:order_line_item, order: order) }
  let!(:survivor) do
    pkg = create(:package, shopify_store: store, order: order, number: 600, aasm_state: "pending_process")
    create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 2)
    pkg
  end
  let!(:other) do
    pkg = create(:package, shopify_store: store, order: order, number: 601, aasm_state: "pending_process")
    create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 1)
    pkg
  end

  it "merges the order's boxes back into one and returns turbo_stream" do
    post merge_package_path(id: other.id),
         headers: { "Accept" => "text/vnd.turbo-stream.html" }
    expect(response).to have_http_status(:ok)
    expect(store.packages.where(order_id: order.id).count).to eq(1)
    expect(survivor.reload.package_items.find_by(order_line_item_id: oli.id).quantity).to eq(3)
  end

  it "forbids a member without package_process permission" do
    other_user = create(:user)
    create(:membership, user: other_user, company: company, role: :member, permissions: [ "package_review" ])
    sign_in other_user
    post merge_package_path(id: other.id)
    expect(response).to have_http_status(:found)
    expect(store.packages.where(order_id: order.id).count).to eq(2)
  end
end
```

> 註：上面 member 權限測試以 `create(:membership, ...)` 建 member 身分；請對照該 spec 既有的 member 建法（若既有以 `:member_with_group` trait，沿用它）調整這兩段，保持與檔案內其他權限測試一致。

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/requests/packages_spec.rb -e "split" -e "merge"`
Expected: FAIL — `undefined method 'split_package_path'`（route 未定義）。

- [ ] **Step 3: Add routes**

`config/routes.rb` 的 packages member block 加兩行：

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
      end
      collection { post :sync }
    end
```

- [ ] **Step 4: Add controller actions**

`app/controllers/packages_controller.rb`：把 `before_action :set_package` 那行的 `only:` 陣列加入 `:split, :merge`：

```ruby
  before_action :set_package, only: [ :show, :transition, :update_address, :update_item, :update_logistics, :update_note, :split, :merge ]
```

在 `update_note` 之後、`private` 之前加入：

```ruby
  # Folds this pending_process package into new sibling boxes (see
  # PackageSplitter). Gated on package_process, same as the other manual edits.
  # Invalid allocations re-render the modal at 422 (never 500); a non-
  # pending_process source is rejected before the service runs.
  def split
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    unless @package.pending_process?
      return redirect_to(package_path(id: @package.id), alert: t("packages.split_invalid_state"))
    end

    result = PackageSplitter.new(@package, split_allocations).call
    if result.success?
      respond_to do |format|
        format.turbo_stream { render :split }
        format.html { redirect_to package_path(id: @package.id), notice: t("packages.split_done") }
      end
    else
      @split_errors = result.errors
      respond_to do |format|
        format.turbo_stream { render :split, status: :unprocessable_entity }
        format.html { redirect_to package_path(id: @package.id), alert: t("packages.split_invalid") }
      end
    end
  end

  # Collapses this order's split boxes back into the lowest-numbered survivor
  # (see PackageMerger). Gated on package_process. The modal reloads to show the
  # survivor; count returns to 1 so auto-sync resumes on the next order sync.
  def merge
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    unless @package.pending_process?
      return redirect_to(package_path(id: @package.id), alert: t("packages.split_invalid_state"))
    end

    @survivor = PackageMerger.new(@package).call
    respond_to do |format|
      format.turbo_stream { render :merge }
      format.html { redirect_to package_path(id: @survivor.id), notice: t("packages.merge_done") }
    end
  end
```

在 `private` 區塊（例如 `customs_item_params` 附近）加入 params 解析：

```ruby
  # Split allocations arrive as a dynamic hash keyed by order_line_item UUIDs
  # ({ li_id => [box1_units, box2_units, ...] }), so a fixed strong-params
  # permit list can't name the keys. to_unsafe_h is safe here: every key is
  # validated against the source package's own items inside PackageSplitter
  # (unknown ids → :unknown_item, 422), and values are coerced to integers, so
  # nothing user-controlled reaches a query or mass-assignment unchecked.
  def split_allocations
    raw = params[:allocations]
    return {} unless raw.respond_to?(:to_unsafe_h) || raw.is_a?(Hash)

    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    raw.to_h.transform_values { |arr| Array(arr).map { |v| v.to_s.to_i } }
  end
```

- [ ] **Step 5: Add turbo_stream templates**

`app/views/packages/split.turbo_stream.erb`：

```erb
<%# Success and failure both reload the source modal. On failure @split_errors
    is passed through so the split dialog re-opens showing the error banner. %>
<%= turbo_stream.replace "package-modal",
      partial: "packages/modal",
      locals: { package: @package.reload, split_errors: @split_errors } %>
```

`app/views/packages/merge.turbo_stream.erb`：

```erb
<%= turbo_stream.replace "package-modal",
      partial: "packages/modal",
      locals: { package: @survivor.reload } %>
```

- [ ] **Step 6: Run to verify they pass**

Run: `bundle exec rspec spec/requests/packages_spec.rb -e "split" -e "merge"`
Expected: PASS。（此時 `_modal` 尚未接受 `split_errors` local — 下一 Task 加；因 turbo_stream 只是渲染 modal，多傳一個未使用 local 不會報錯，但若 `_modal` 用 strict locals 會失敗。`_modal` 目前非 strict locals，安全。）

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/packages_controller.rb app/views/packages/split.turbo_stream.erb app/views/packages/merge.turbo_stream.erb spec/requests/packages_spec.rb
git commit -m "feat(packing): add split/merge controller actions + routes"
```

---

### Task 6: UI — 兄弟包裹列、折包對話框、Stimulus、i18n

**Files:**
- Create: `app/views/packages/_siblings_strip.html.erb`
- Create: `app/views/packages/_split_dialog.html.erb`
- Create: `app/javascript/controllers/split_controller.js`
- Modify: `app/views/packages/_modal.html.erb`
- Modify: `config/locales/en.yml`, `config/locales/zh-TW.yml`, `config/locales/zh-CN.yml`
- Test:（system spec 在 Task 7）

**Interfaces:**
- Consumes: `Package#order_packages` / `#split?`、`PackageMerger#conflict?`、`Package#shippable_items`、`split_package_path` / `merge_package_path`。
- Produces: 折包狀態的 Modal 頂部兄弟列（切換 + 合并 + 凍結提示）；`pending_process` 的折包對話框（矩陣，動態加/移除包裹欄、即時餘數/小計/驗證）；`split` Stimulus controller。

- [ ] **Step 1: Add i18n keys**

在三個 locale 檔的 `packages:` 節點下加入（值：en 英、zh-TW 繁、zh-CN 简；以下示範 zh-TW，另兩檔對應翻譯）：

```yaml
    split:
      button: "折包"
      title: "拆分訂單"
      add_box: "新增包裹"
      remove_box: "移除此包裹"
      col_product: "商品資訊"
      col_customs: "報關資訊"
      col_total: "總數"
      remainder_box: "包裹1"
      box_label: "包裹%{n}"
      footer_kinds_qty: "商品種類/總數量"
      footer_weight: "總重量"
      submit: "拆分"
      cancel: "取消"
      done: "已折出新包裹"
      invalid: "折包資料有誤，請檢查數量分配"
      invalid_state: "只有待處理的包裹可以折包"
      errors:
        empty: "尚未分配任何數量"
        ragged: "各包裹的欄位數不一致"
        unknown_item: "包含未知的商品項"
        negative: "數量不可為負數"
        over_allocated: "分配數量超過可出貨數"
        empty_box: "有包裹沒有分配任何商品"
        empty_source: "原包裹必須保留至少一件可出貨商品"
    merge:
      button: "合併"
      done: "已合併回單一包裹"
      confirm: "確定合併？將把所有分箱塌回原始包裹。"
      confirm_conflict: "各分箱的收件地址或物流渠道不一致，合併後將只保留原始包裹（包裹1）的地址與物流，其餘丟棄。確定合併？"
    frozen_notice: "此訂單已折包，Shopify 自動同步暫停；若發生整單全退需人工處理（可先合併再處理）。"
```

en.yml 對應英文、zh-CN.yml 對應简体（`折包`→`折包`、`拆分訂單`→`拆分订单` 等）。**三檔的 key 結構必須相同**，否則 CI 的 i18n 檢查會失敗。

- [ ] **Step 2: Add the siblings strip partial**

`app/views/packages/_siblings_strip.html.erb`：

```erb
<%# Shown only while the order is folded into multiple boxes. Lists the order's
    sibling packages (switchable via the modal Turbo Frame), the Merge button
    (conflict-aware confirm text), and the frozen-auto-sync notice. Stable
    dom_id so future edits can turbo_stream-replace it if needed. %>
<div id="<%= dom_id(package, :siblings_strip) %>">
  <% if package.split? %>
    <div class="mx-6 mt-3 px-4 py-3 rounded-md bg-indigo-50 border border-indigo-200 text-sm">
      <div class="flex items-center flex-wrap gap-2">
        <span class="text-xs font-medium text-indigo-800"><%= t("packages.split.title") %>:</span>
        <% package.order_packages.each do |sib| %>
          <% if sib.id == package.id %>
            <span class="px-2 py-1 rounded bg-indigo-600 text-white text-xs font-mono"><%= sib.package_code %></span>
          <% else %>
            <%= link_to sib.package_code, package_path(id: sib.id),
                  data: { turbo_frame: "package-modal" },
                  class: "px-2 py-1 rounded bg-white border border-indigo-300 text-indigo-700 text-xs font-mono hover:bg-indigo-100" %>
          <% end %>
        <% end %>

        <% if package.pending_process? %>
          <%= button_to t("packages.merge.button"),
                merge_package_path(id: package.id), method: :post,
                form: { data: { turbo_frame: "package-modal" } },
                data: { turbo_confirm: PackageMerger.new(package).conflict? ? t("packages.merge.confirm_conflict") : t("packages.merge.confirm") },
                class: "ml-auto px-3 py-1 bg-indigo-600 text-white text-xs rounded hover:bg-indigo-700" %>
        <% end %>
      </div>
      <p class="mt-2 text-xs text-indigo-700"><%= t("packages.frozen_notice") %></p>
    </div>
  <% end %>
</div>
```

- [ ] **Step 3: Add the split dialog partial**

`app/views/packages/_split_dialog.html.erb`（矩陣對話框；用 `<template>` 讓 Stimulus 複製包裹欄 header/儲存格）：

```erb
<%# Split dialog: matrix of shippable items × boxes. Box 1 (source remainder)
    is auto-computed; boxes 2..N are inputs. The split controller clones the
    per-row/header templates to add/remove box columns and live-updates the
    remainder, per-box footers, and submit-disabled state. Rendered only for a
    pending_process, not-yet-split package. %>
<% if package.pending_process? && !package.split? %>
  <div data-controller="split" class="mt-3 px-6">
    <button type="button" data-action="split#open"
            class="px-4 py-2 bg-purple-600 text-white text-sm rounded hover:bg-purple-700">
      <%= t("packages.split.button") %>
    </button>

    <div data-split-target="dialog" class="hidden mt-3 border border-gray-200 rounded-md p-4 bg-gray-50">
      <div class="flex items-center justify-between mb-3">
        <h4 class="text-sm font-semibold text-gray-900"><%= t("packages.split.title") %></h4>
        <button type="button" data-action="split#addBox"
                class="text-xs text-blue-600 hover:underline"><%= t("packages.split.add_box") %></button>
      </div>

      <% if defined?(split_errors) && split_errors.present? %>
        <div class="mb-3 px-3 py-2 rounded bg-red-50 border border-red-200 text-red-800 text-xs">
          <ul class="list-disc list-inside">
            <% split_errors.each do |code| %>
              <li><%= t("packages.split.errors.#{code}", default: code.to_s) %></li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <%= form_with url: split_package_path(id: package.id), method: :post,
            data: { turbo_frame: "package-modal", split_target: "form" } do %>
        <table class="w-full text-xs border-collapse">
          <thead>
            <tr class="text-left text-gray-500 border-b border-gray-200" data-split-target="headerRow">
              <th class="py-1 pr-2"><%= t("packages.split.col_product") %></th>
              <th class="py-1 px-2 text-center"><%= t("packages.split.col_total") %></th>
              <th class="py-1 px-2 text-center"><%= t("packages.split.remainder_box") %></th>
              <%# box header cells appended here by split#addBox %>
            </tr>
          </thead>
          <tbody>
            <% package.shippable_items.each do |item| %>
              <% shippable = item.quantity - item.refunded_quantity %>
              <tr class="border-b border-gray-100"
                  data-split-target="row"
                  data-line-item-id="<%= item.order_line_item_id %>"
                  data-shippable="<%= shippable %>">
                <td class="py-2 pr-2">
                  <span class="font-mono"><%= item.sku %></span>
                  <span class="text-gray-500"><%= item.title %></span>
                </td>
                <td class="py-2 px-2 text-center"><%= shippable %></td>
                <td class="py-2 px-2 text-center font-medium" data-split-target="remainder"><%= shippable %></td>
                <%# box input cells appended here by split#addBox %>
              </tr>
            <% end %>
          </tbody>
        </table>

        <div class="mt-3 flex items-center gap-2">
          <button type="submit" data-split-target="submit"
                  class="px-4 py-2 bg-purple-600 text-white text-sm rounded hover:bg-purple-700 disabled:opacity-40 disabled:cursor-not-allowed">
            <%= t("packages.split.submit") %>
          </button>
          <button type="button" data-action="split#close"
                  class="px-4 py-2 bg-gray-200 text-gray-700 text-sm rounded hover:bg-gray-300">
            <%= t("packages.split.cancel") %>
          </button>
        </div>
      <% end %>

      <%# Templates cloned per added box. %>
      <template data-split-target="headerCellTemplate">
        <th class="py-1 px-2 text-center">
          <span data-split-target="boxLabel"></span>
          <button type="button" data-action="split#removeBox" class="ml-1 text-red-500 hover:text-red-700" title="<%= t("packages.split.remove_box") %>">&times;</button>
        </th>
      </template>
      <template data-split-target="cellTemplate">
        <td class="py-2 px-2 text-center">
          <input type="number" min="0" value="0"
                 data-split-target="input" data-action="input->split#recompute"
                 class="w-14 border border-gray-300 rounded px-1 py-0.5 text-center">
        </td>
      </template>
    </div>
  </div>
<% end %>
```

- [ ] **Step 4: Add the split Stimulus controller**

`app/javascript/controllers/split_controller.js`：

```javascript
import { Controller } from "@hotwired/stimulus"

// Drives the split dialog: open/close, add/remove box columns, and live
// recompute of per-item remainder (box 1), per-box empties, and submit-enabled.
// Box inputs are named `allocations[<lineItemId>][]`; appended in the same box
// order across every row, so each item's submitted array aligns by box index.
export default class extends Controller {
  static targets = [
    "dialog", "form", "headerRow", "row", "remainder", "submit",
    "headerCellTemplate", "cellTemplate", "boxLabel", "input"
  ]

  connect() { this.boxCount = 0 }

  open() { this.dialogTarget.classList.remove("hidden"); if (this.boxCount === 0) this.addBox() }
  close() { this.dialogTarget.classList.add("hidden") }

  addBox() {
    this.boxCount += 1
    const idx = this.boxCount

    const header = this.headerCellTemplateTarget.content.cloneNode(true)
    header.querySelector("[data-split-target='boxLabel']").textContent =
      this.boxLabelText(idx)
    this.headerRowTarget.appendChild(header)

    const lineItemIds = []
    this.rowTargets.forEach((row) => {
      const cell = this.cellTemplateTarget.content.cloneNode(true)
      const input = cell.querySelector("input")
      input.name = `allocations[${row.dataset.lineItemId}][]`
      input.max = row.dataset.shippable
      row.appendChild(cell)
      lineItemIds.push(row.dataset.lineItemId)
    })
    this.recompute()
  }

  removeBox(event) {
    const th = event.currentTarget.closest("th")
    const cellIndex = Array.from(this.headerRowTarget.children).indexOf(th)
    th.remove()
    this.rowTargets.forEach((row) => {
      const cell = row.children[cellIndex]
      if (cell) cell.remove()
    })
    this.boxCount -= 1
    this.relabel()
    this.recompute()
  }

  relabel() {
    // header box labels start at column index 3 (after product/total/remainder)
    this.boxLabelTargets.forEach((label, i) => {
      label.textContent = this.boxLabelText(i + 1)
    })
  }

  boxLabelText(n) { return `${this.data.get("boxWord") || "包裹"}${n + 1}` }

  recompute() {
    let anyBoxEmpty = false
    let sourceRemainderTotal = 0
    let overAllocated = false

    // per-box totals
    const boxTotals = new Array(this.boxCount).fill(0)

    this.rowTargets.forEach((row, rowIdx) => {
      const shippable = parseInt(row.dataset.shippable, 10) || 0
      const inputs = row.querySelectorAll("input[data-split-target='input']")
      let moved = 0
      inputs.forEach((input, boxIdx) => {
        const v = parseInt(input.value, 10) || 0
        moved += v
        boxTotals[boxIdx] = (boxTotals[boxIdx] || 0) + v
      })
      const remainder = shippable - moved
      if (remainder < 0) overAllocated = true
      sourceRemainderTotal += Math.max(remainder, 0)
      this.remainderTargets[rowIdx].textContent = remainder
      this.remainderTargets[rowIdx].classList.toggle("text-red-600", remainder < 0)
    })

    boxTotals.forEach((t) => { if (t <= 0) anyBoxEmpty = true })

    const valid =
      this.boxCount > 0 && !anyBoxEmpty && !overAllocated && sourceRemainderTotal > 0
    this.submitTarget.disabled = !valid
  }
}
```

> 注：`boxLabelText` 的 `包裹` 字樣改由 view 傳入避免硬編中文 —— 在 `_split_dialog` 的 `data-controller="split"` 元素加 `data-split-box-word="<%= t('packages.split.box_word', default: '包裹') %>"`，並在 i18n 補 `split.box_word`。若團隊接受硬編可略過。

- [ ] **Step 5: Wire strip + dialog into the modal**

`app/views/packages/_modal.html.erb`：在 `order_cancelled?` 提示區塊之後、`grid grid-cols-2...` 摘要之前，插入兄弟列；並在底部 `actions` 區塊之後插入折包對話框，同時把 `split_errors` local 傳下去。

在 `<% if package.order_cancelled? %> ... <% end %>` 之後加：

```erb
    <%= render "packages/siblings_strip", package: package %>
```

把底部 actions 區塊替換為（多 render 一個 split_dialog，並傳 `split_errors`）：

```erb
    <div id="<%= dom_id(package, :actions) %>" class="border-t border-gray-100 px-6 py-3">
      <%= render "packages/actions", package: package %>
      <%= render "packages/split_dialog", package: package, split_errors: local_assigns[:split_errors] %>
    </div>
```

- [ ] **Step 6: Manual smoke check（可選，非測試）**

Run: `bin/dev` 後開 `/packages?state=pending_process`，點一個包裹 → 應見「折包」按鈕；按下展開矩陣、可「新增包裹」、輸入數量時包裹1 餘數即時更新、空箱時「拆分」鈕 disabled。折包後頂部出現兄弟包裹列與「合併」。（正式驗證在 Task 7 system spec。）

- [ ] **Step 7: Commit**

```bash
git add app/views/packages/_siblings_strip.html.erb app/views/packages/_split_dialog.html.erb app/javascript/controllers/split_controller.js app/views/packages/_modal.html.erb config/locales/en.yml config/locales/zh-TW.yml config/locales/zh-CN.yml
git commit -m "feat(packing): split dialog + siblings strip UI and split Stimulus controller"
```

---

### Task 7: System specs（真 Chrome，Turbo 契約）

**Files:**
- Modify: `spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: 全部 Task 1–6 的 UI 與 action。

- [ ] **Step 1: Write the failing system tests**

在 `spec/system/packages_spec.rb` 新增（沿用該檔 `sign_in_as(user)` 與 `let` 慣例）：

```ruby
describe "折包 / 合併" do
  let(:split_order) { create(:order, customer: customer, shopify_store: store, name: "PKS#SPLIT1") }
  let(:oli) { create(:order_line_item, order: split_order) }
  let!(:source_pkg) do
    pkg = create(:package, shopify_store: store, order: split_order, number: 700, aasm_state: "pending_process")
    create(:package_item, package: pkg, order_line_item: oli, sku: "SPLITSKU", title: "Splittable", quantity: 3)
    pkg
  end

  it "folds a package into a new sibling box via the matrix dialog" do
    visit packages_path(state: "pending_process")
    click_link source_pkg.package_code
    expect(page).to have_button(I18n.t("packages.split.button"))

    click_button I18n.t("packages.split.button")
    expect(page).to have_content(I18n.t("packages.split.title"))

    # allocate 1 unit to box 2; submit becomes enabled
    fill_in_first_box_input("1")
    click_button I18n.t("packages.split.submit")

    # after split: siblings strip appears with two package codes
    expect(page).to have_css("[id$='siblings_strip']")
    expect(store.packages.where(order_id: split_order.id).count).to eq(2)
    expect(page).to have_content(I18n.t("packages.frozen_notice"))
  end

  it "disables submit when a box is empty (no allocation)" do
    visit packages_path(state: "pending_process")
    click_link source_pkg.package_code
    click_button I18n.t("packages.split.button")
    expect(page).to have_button(I18n.t("packages.split.submit"), disabled: true)
  end

  it "merges split boxes back into one and shows the survivor" do
    other = create(:package, shopify_store: store, order: split_order, number: 701, aasm_state: "pending_process")
    create(:package_item, package: other, order_line_item: oli, sku: "SPLITSKU", quantity: 1)
    source_pkg.package_items.first.update!(quantity: 2)

    visit packages_path(state: "pending_process")
    click_link source_pkg.package_code
    expect(page).to have_css("[id$='siblings_strip']")

    accept_confirm { click_button I18n.t("packages.merge.button") }

    expect(store.packages.where(order_id: split_order.id).count).to eq(1)
    expect(source_pkg.reload.package_items.sum(:quantity)).to eq(3)
  end
end

# Fills the first box's number input for the first item row.
def fill_in_first_box_input(value)
  first("input[name^='allocations']").set(value)
end
```

- [ ] **Step 2: Run to verify they fail (then pass after wiring)**

Run: `bundle exec rspec spec/system/packages_spec.rb -e "折包 / 合併"`
Expected: 起初可能 FAIL（若 Task 6 尚未全綠）；Task 6 完成後應 PASS。若本機 chromedriver 版本超前 Chrome，依記憶 [[local-system-test-chromedriver]] 把 `/tmp/chromedriver-linux64` 前置 PATH。

> 註：`fill_in_first_box_input` 依賴輸入 `input->split#recompute` 觸發 enable。若 `.set` 未觸發 input 事件，改用 `find(...).send_keys` 或 `execute_script` 派發 `input` 事件。

- [ ] **Step 3: Commit**

```bash
git add spec/system/packages_spec.rb
git commit -m "test(packing): system specs for split dialog and merge"
```

---

### Task 8: 全套驗證 + 收尾

**Files:** 無新增（跑檢查、修殘留）。

- [ ] **Step 1: Full suite**

Run: `bundle exec rspec`
Expected: 全綠、coverage ≥ 95%。若某新檔覆蓋不足，補測分支（splitter 驗證各錯誤碼、merger conflict 各路徑、auto_builder 三分支）。

- [ ] **Step 2: Lint + security**

Run: `bin/rubocop && bin/brakeman --no-pager`
Expected: RuboCop 無 offense；Brakeman 無新警告（特別留意 `split_allocations` 的 `to_unsafe_h` — 已在註解說明其安全性，Brakeman 若標記 mass-assignment，確認未直接 permit 進 model）。

- [ ] **Step 3: Update handoff doc（承接慣例）**

在 `docs/superpowers/HANDOFF_order_packing_phase2b3.md` 第一節進度表把 2B-3 標為完成，並於文末補一行 2B-3 已交付摘要（折包/合併、凍結/恢復）。Commit：

```bash
git add docs/superpowers/HANDOFF_order_packing_phase2b3.md
git commit -m "docs(packing): mark Phase 2B-3 split/merge delivered"
```

- [ ] **Step 4: Push + PR to staging**

```bash
git push -u origin feature/order-packing-phase2b3
```

用 `gh pr create --base staging` 開 PR（標題 `feat(packing): Phase 2B-3 折包(拆分)+合併`，內文列出決策 Q1–Q5、凍結/恢復語意、測試涵蓋）。PR 內文結尾加：
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`

---

## Self-Review（對照 spec）

- **Spec 覆蓋**：資料模型/migration→T1；auto-builder 凍結+recover+全退邊界→T2；退款不變量/繼承/驗證→T3；合併塌回+衝突偵測→T4；controller/route/權限/422→T5；矩陣 UI/兄弟列/凍結提示/Stimulus/i18n→T6；system(Turbo)→T7；驗證/PR→T8。全部有對應任務。
- **Placeholder 掃描**：無 TBD/TODO；每個 code step 附完整程式碼與指令。
- **型別一致**：`PackageSplitter.new(source, allocations).call → Result(success?/source/new_packages/errors)`、`PackageMerger.new(pkg_or_order)` 具 `#call/#conflict?/#pending_siblings`、`Package#order_packages/#split?`、route helper `split_package_path/merge_package_path`、params key `allocations` 於 T5/T6 一致；Stimulus target 名稱（dialog/form/headerRow/row/remainder/submit/headerCellTemplate/cellTemplate/boxLabel/input）於 partial 與 controller 對齊。
- **已知需執行時對齊處**（已在步驟就地標註）：request spec 的 member 身分建法對齊該檔既有慣例；system spec `.set` 觸發 input 事件；`_modal` 非 strict-locals 才能安全接 `split_errors`（若日後改 strict locals，需在 magic comment 宣告，注意記憶 [[erb-strict-locals-magic-comment]]）。
