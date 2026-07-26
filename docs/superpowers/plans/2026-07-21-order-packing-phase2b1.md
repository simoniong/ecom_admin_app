# Order Packing Phase 2B-1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give packages per-package snapshots (shipping address + per-item customs), a per-store manual "sync orders" button, smart re-sync (refresh snapshots unless manually overridden), and item-level refund flagging — so a re-synced order updates the package correctly and refunded items are visibly marked "do not ship".

**Architecture:** Extend the existing `PackageAutoBuilder` (which already runs on every order sync via `SyncAllOrdersService#sync_order`) to (a) snapshot address+customs at build time, (b) smart-update an existing non-terminal package on re-sync honoring per-section override flags, and (c) compute per-item `refunded_quantity` from `order.shopify_data["refunds"]`. Add a manual sync trigger button to the packing list pages (enqueues the existing per-store `SyncAllShopifyOrdersJob`), and a refund-warning badge on the list row.

**Tech Stack:** Rails 8.1, PostgreSQL UUID PKs, Solid Queue, Hotwire/Turbo, Tailwind, RSpec + FactoryBot.

## Global Constraints

- All table IDs use UUIDs. Migrations `def change` + `add_column`.
- RSpec + FactoryBot, no fixtures; ≥95% line coverage. No mocks (no external boundary in 2B-1 — the sync button enqueues a job; specs assert the enqueue).
- Turbo-driven UI ships a system spec in the same commit.
- i18n keys in all three locales: `config/locales/en.yml`, `config/locales/zh-TW.yml`, `config/locales/zh-CN.yml`.
- Route helpers take keyword ids under the `scope "(:locale)"` wrapper.
- Never commit to `main`/`staging`; work on `feature/order-packing-phase2b1` (already off `origin/staging`, includes 2A).
- Design: `docs/superpowers/specs/2026-07-21-order-packing-phase2b1-design.md`. PRD: `.plan/PRD_order_packing.md`.
- **2B-1 is snapshot/sync infra + read-only refund display ONLY.** NO detail page, NO edit operations (edit address/customs/note, assign logistics, review/hold/back buttons are 2B-2), NO folding (2B-3). Override flags are created here but stay `false` — nothing sets them yet, so re-sync always refreshes; 2B-2's edit actions will set them.

## Key existing facts (verified — trust these)

- `PackageAutoBuilder#do_call` (app/services/package_auto_builder.rb): refunds an existing package on full refund (any state), else creates a new package when `packing_enabled?` + `eligible?` + no existing. `build_package` copies line items into package_items inside a store row lock. Item copy maps `li.product_variant_id`, `li.id`→`order_line_item_id`, `li.sku_at_sale`→`sku`, `li.title_at_sale`→`title`, `li.quantity`→`quantity`.
- `order.shopify_data` holds the full Shopify order payload. Item refunds live in `order.shopify_data["refunds"]` — an array; each entry has `"refund_line_items"` (array of `{ "line_item_id" => <shopify_line_item_id>, "quantity" => N }`). There is no existing refund parsing.
- Map a Shopify refund line to a package_item: refund `line_item_id` == `order_line_item.shopify_line_item_id`; `package_item.order_line_item_id` == that order_line_item's id.
- `ProductVariant` customs fields: `customs_name_zh`, `customs_name_en`, `declared_value_usd`, `hs_code`, `import_hs_code`, `weight_grams`.
- `SyncAllShopifyOrdersJob.perform_later(store.id)` syncs one store (see `OrdersController#sync`, which enqueues it per `visible_shopify_stores`).
- Package AASM terminal state is `refunded`; `package.refunded?` predicate exists. Smart-update must skip refunded packages.

## File Structure

- `db/migrate/*_add_snapshot_fields_to_packages.rb`, `*_add_customs_and_refund_fields_to_package_items.rb` (Task 1)
- `app/models/package.rb`, `app/models/package_item.rb` (Task 1 — validations/helpers)
- `app/services/package_auto_builder.rb` (Task 2 build-time snapshot; Task 3 smart re-sync + refund detection)
- `app/controllers/packages_controller.rb`, `config/routes.rb` (Task 4 — sync action)
- `app/views/packages/index.html.erb` (Task 4 — sync button), `app/views/packages/_package_row.html.erb` (Task 5 — refund badge)
- `config/locales/*.yml`, specs alongside each task.

---

### Task 1: Snapshot + refund columns on packages / package_items

**Files:**
- Create: `db/migrate/20260721150001_add_snapshot_fields_to_packages.rb`, `db/migrate/20260721150002_add_customs_and_refund_fields_to_package_items.rb`
- Modify: `app/models/package.rb`, `app/models/package_item.rb`
- Test: `spec/models/package_spec.rb`, `spec/models/package_item_spec.rb`

**Interfaces:**
- Produces: `Package#shipping_address_snapshot` (jsonb, default {}), `#address_overridden` (bool). `PackageItem#customs_name_zh/customs_name_en/declared_value_usd/hs_code/import_hs_code/customs_weight_grams`, `#customs_overridden` (bool), `#refunded_quantity` (int, default 0), `#fully_refunded?` (refunded_quantity >= quantity). Consumed by Tasks 2/3/5.

- [ ] **Step 1: Migrations**
```ruby
# 20260721150001_add_snapshot_fields_to_packages.rb
class AddSnapshotFieldsToPackages < ActiveRecord::Migration[8.1]
  def change
    # Per-package snapshot of the order's shipping address, taken at build
    # time and smart-refreshed on re-sync unless address_overridden is set
    # (2B-2's address edit sets the flag). Per-package so folding (2B-3) gives
    # each split package its own address.
    add_column :packages, :shipping_address_snapshot, :jsonb, null: false, default: {}
    add_column :packages, :address_overridden, :boolean, null: false, default: false
  end
end
```
```ruby
# 20260721150002_add_customs_and_refund_fields_to_package_items.rb
class AddCustomsAndRefundFieldsToPackageItems < ActiveRecord::Migration[8.1]
  def change
    # Per-item customs snapshot copied from the product_variant at build time,
    # smart-refreshed on re-sync unless customs_overridden (2B-2's customs edit
    # sets it). refunded_quantity tracks how many units Shopify refunded/cancelled
    # so the packer sees "do not ship".
    add_column :package_items, :customs_name_zh, :string
    add_column :package_items, :customs_name_en, :string
    add_column :package_items, :declared_value_usd, :decimal, precision: 10, scale: 2
    add_column :package_items, :hs_code, :string
    add_column :package_items, :import_hs_code, :string
    add_column :package_items, :customs_weight_grams, :decimal, precision: 12, scale: 3
    add_column :package_items, :customs_overridden, :boolean, null: false, default: false
    add_column :package_items, :refunded_quantity, :integer, null: false, default: 0
  end
end
```
Run: `bin/rails db:migrate && bin/rails db:test:prepare`.

- [ ] **Step 2: Failing model specs**

Add to `spec/models/package_item_spec.rb`:
```ruby
describe "refund tracking" do
  it "defaults refunded_quantity to 0" do
    expect(build(:package_item).refunded_quantity).to eq(0)
  end

  it "is fully_refunded? when refunded_quantity >= quantity" do
    expect(build(:package_item, quantity: 3, refunded_quantity: 3).fully_refunded?).to be(true)
    expect(build(:package_item, quantity: 3, refunded_quantity: 1).fully_refunded?).to be(false)
    expect(build(:package_item, quantity: 3, refunded_quantity: 0).fully_refunded?).to be(false)
  end

  it "rejects a negative refunded_quantity" do
    expect(build(:package_item, refunded_quantity: -1)).not_to be_valid
  end
end
```
Add to `spec/models/package_spec.rb`:
```ruby
describe "snapshot fields" do
  it "defaults shipping_address_snapshot to {} and address_overridden to false" do
    pkg = create(:package)
    expect(pkg.shipping_address_snapshot).to eq({})
    expect(pkg.address_overridden).to be(false)
  end
end
```

- [ ] **Step 3: Run — expect failure.** `bundle exec rspec spec/models/package_item_spec.rb spec/models/package_spec.rb` → FAIL (`fully_refunded?` undefined; refunded_quantity validation missing).

- [ ] **Step 4: Implement models**

`app/models/package_item.rb` — add validation + helper:
```ruby
  validates :refunded_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def fully_refunded?
    refunded_quantity >= quantity
  end
```
`app/models/package.rb` — no new validation needed (jsonb default handled by DB); the columns are already accessible. (Optionally add `store_accessor` — not required.)

- [ ] **Step 5: Run — expect pass.** `bundle exec rspec spec/models/package_item_spec.rb spec/models/package_spec.rb` → PASS.

- [ ] **Step 6: Commit**
```bash
bin/rubocop app/models/package.rb app/models/package_item.rb
git add db/migrate app/models/package.rb app/models/package_item.rb db/schema.rb spec/models/package_spec.rb spec/models/package_item_spec.rb
git commit -m "feat(packing): package address snapshot + package_item customs snapshot & refund columns"
```

---

### Task 2: Snapshot address + customs at build time

**Files:**
- Modify: `app/services/package_auto_builder.rb` (`build_package`)
- Test: `spec/services/package_auto_builder_spec.rb`

**Interfaces:**
- Consumes: Task 1 columns. Produces: at build time, `package.shipping_address_snapshot` = order's shipping address; each `package_item` carries a customs snapshot from its variant; `refunded_quantity` computed. Consumed by Task 3 (re-sync recomputes) and 2B-2 (edits these).

- [ ] **Step 1: Failing spec**

Add to `spec/services/package_auto_builder_spec.rb`:
```ruby
describe "build-time snapshots" do
  let(:store) { create(:shopify_store, packing_enabled: true, package_prefix: "XMBDE", package_number_start: 2013094) }
  before { store.update_columns(packing_enabled_at: 1.year.ago) }

  let(:variant) { create(:product_variant, customs_name_zh: "積木", customs_name_en: "Blocks", declared_value_usd: 5, hs_code: "9503", import_hs_code: "9503.00", weight_grams: 250) }
  let(:order) do
    o = create(:order, shopify_store: store, financial_status: "paid", ordered_at: Time.current,
               shopify_data: { "shipping_address" => { "name" => "Jane", "address1" => "1 Main St", "city" => "NYC", "zip" => "10001", "country_code" => "US" } })
    create(:order_line_item, order: o, product_variant: variant, sku_at_sale: "WP-1", title_at_sale: "Puzzle", quantity: 2)
    o
  end

  it "snapshots the order's shipping address onto the package" do
    described_class.new(order).call
    pkg = store.packages.find_by(order: order)
    expect(pkg.shipping_address_snapshot["city"]).to eq("NYC")
    expect(pkg.shipping_address_snapshot["country_code"]).to eq("US")
    expect(pkg.address_overridden).to be(false)
  end

  it "snapshots the variant's customs info onto each package_item" do
    described_class.new(order).call
    item = store.packages.find_by(order: order).package_items.first
    expect(item.customs_name_zh).to eq("積木")
    expect(item.customs_name_en).to eq("Blocks")
    expect(item.declared_value_usd).to eq(5)
    expect(item.hs_code).to eq("9503")
    expect(item.import_hs_code).to eq("9503.00")
    expect(item.customs_weight_grams).to eq(250)
    expect(item.customs_overridden).to be(false)
    expect(item.refunded_quantity).to eq(0)
  end

  it "leaves customs nil when the line item has no product_variant" do
    order.order_line_items.first.update!(product_variant: nil)
    described_class.new(order).call
    item = store.packages.find_by(order: order).package_items.first
    expect(item.customs_name_zh).to be_nil
  end
end
```

- [ ] **Step 2: Run — expect failure.** `bundle exec rspec spec/services/package_auto_builder_spec.rb -e "build-time snapshots"` → FAIL.

- [ ] **Step 3: Implement in `build_package`**

Replace the `build_package`'s create block so the package carries the address snapshot and each item carries customs. Target:
```ruby
  def build_package
    @store.with_lock do
      return if @store.packages.exists?(order_id: @order.id)

      seq = @store.package_number_seq || @store.package_number_start
      @store.update!(package_number_seq: seq + 1)
      package = @store.packages.create!(
        order: @order,
        number: seq,
        shipping_address_snapshot: @order.shopify_data["shipping_address"] || {}
      )
      refunds = refunded_quantities  # { shopify_line_item_id => qty }
      @order.order_line_items.find_each do |li|
        package.package_items.create!(
          customs_attributes_for(li).merge(
            product_variant_id: li.product_variant_id,
            order_line_item_id: li.id,
            sku: li.sku_at_sale,
            title: li.title_at_sale,
            quantity: li.quantity,
            refunded_quantity: refunds[li.shopify_line_item_id] || 0
          )
        )
      end
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # Customs snapshot copied from the line item's product_variant (nil-safe).
  def customs_attributes_for(line_item)
    v = line_item.product_variant
    return {} unless v
    {
      customs_name_zh: v.customs_name_zh,
      customs_name_en: v.customs_name_en,
      declared_value_usd: v.declared_value_usd,
      hs_code: v.hs_code,
      import_hs_code: v.import_hs_code,
      customs_weight_grams: v.weight_grams
    }
  end
```
The `refunded_quantities` helper is added in Task 3 (it's shared by build + re-sync). For Task 2 to run green standalone, add a minimal version now (Task 3 expands it):
```ruby
  # Sum of refunded/cancelled units per shopify_line_item_id, from the order's
  # Shopify payload. { shopify_line_item_id (Integer) => refunded_qty (Integer) }
  def refunded_quantities
    result = Hash.new(0)
    Array(@order.shopify_data["refunds"]).each do |refund|
      Array(refund["refund_line_items"]).each do |rli|
        lid = rli["line_item_id"]
        result[lid] += rli["quantity"].to_i if lid
      end
    end
    result
  end
```

- [ ] **Step 4: Run — expect pass.** `bundle exec rspec spec/services/package_auto_builder_spec.rb -e "build-time snapshots"` → PASS. Also run the whole builder spec to confirm no regression: `bundle exec rspec spec/services/package_auto_builder_spec.rb`.

- [ ] **Step 5: Commit**
```bash
bin/rubocop app/services/package_auto_builder.rb
git add app/services/package_auto_builder.rb spec/services/package_auto_builder_spec.rb
git commit -m "feat(packing): snapshot shipping address + per-item customs at package build"
```

---

### Task 3: Smart re-sync of an existing package + item refund detection

**Files:**
- Modify: `app/services/package_auto_builder.rb` (`do_call` + new `smart_update` path)
- Test: `spec/services/package_auto_builder_spec.rb`

**Interfaces:**
- Consumes: Task 1 columns, Task 2 helpers (`customs_attributes_for`, `refunded_quantities`). Produces: on re-sync of an existing non-terminal package, address/customs refresh unless overridden; item quantities update; new line items added; `refunded_quantity` recomputed. Consumed by 2B-2 (which sets the override flags).

- [ ] **Step 1: Failing spec**

Add to `spec/services/package_auto_builder_spec.rb`:
```ruby
describe "smart re-sync of an existing package" do
  let(:store) { create(:shopify_store, packing_enabled: true, package_prefix: "XMBDE", package_number_start: 1) }
  before { store.update_columns(packing_enabled_at: 1.year.ago) }
  let(:variant) { create(:product_variant, customs_name_en: "Blocks", declared_value_usd: 5, weight_grams: 100) }
  let(:order) do
    o = create(:order, shopify_store: store, financial_status: "paid", ordered_at: Time.current,
               shopify_data: { "shipping_address" => { "city" => "NYC", "country_code" => "US" } })
    create(:order_line_item, order: o, product_variant: variant, shopify_line_item_id: 7001, sku_at_sale: "WP-1", title_at_sale: "Puzzle", quantity: 2)
    o
  end

  def build!
    described_class.new(order).call
    store.packages.find_by(order: order)
  end

  it "refreshes the address snapshot when not overridden" do
    pkg = build!
    order.update!(shopify_data: order.shopify_data.merge("shipping_address" => { "city" => "LA", "country_code" => "US" }))
    described_class.new(order).call
    expect(pkg.reload.shipping_address_snapshot["city"]).to eq("LA")
  end

  it "preserves an overridden address on re-sync" do
    pkg = build!
    pkg.update!(address_overridden: true, shipping_address_snapshot: { "city" => "MANUAL" })
    order.update!(shopify_data: order.shopify_data.merge("shipping_address" => { "city" => "LA" }))
    described_class.new(order).call
    expect(pkg.reload.shipping_address_snapshot["city"]).to eq("MANUAL")
  end

  it "updates an item's quantity when the order line item quantity changes" do
    pkg = build!
    order.order_line_items.first.update!(quantity: 5)
    described_class.new(order).call
    expect(pkg.reload.package_items.first.quantity).to eq(5)
  end

  it "adds a package_item for a newly-added order line item" do
    pkg = build!
    create(:order_line_item, order: order, shopify_line_item_id: 7002, sku_at_sale: "WP-2", title_at_sale: "Puzzle 2", quantity: 1)
    described_class.new(order).call
    expect(pkg.reload.package_items.pluck(:sku)).to contain_exactly("WP-1", "WP-2")
  end

  it "refreshes customs from the variant when not overridden" do
    pkg = build!
    variant.update!(customs_name_en: "Renamed")
    described_class.new(order).call
    expect(pkg.reload.package_items.first.customs_name_en).to eq("Renamed")
  end

  it "preserves overridden customs on re-sync" do
    pkg = build!
    pkg.package_items.first.update!(customs_overridden: true, customs_name_en: "MANUAL")
    variant.update!(customs_name_en: "Renamed")
    described_class.new(order).call
    expect(pkg.reload.package_items.first.customs_name_en).to eq("MANUAL")
  end

  it "marks refunded_quantity from the order's refunds (partial)" do
    pkg = build!
    order.update!(shopify_data: order.shopify_data.merge(
      "refunds" => [ { "refund_line_items" => [ { "line_item_id" => 7001, "quantity" => 1 } ] } ]
    ))
    described_class.new(order).call
    item = pkg.reload.package_items.first
    expect(item.refunded_quantity).to eq(1)
    expect(item.fully_refunded?).to be(false)
  end

  it "flags a fully-refunded item without deleting it" do
    pkg = build!
    order.update!(shopify_data: order.shopify_data.merge(
      "refunds" => [ { "refund_line_items" => [ { "line_item_id" => 7001, "quantity" => 2 } ] } ]
    ))
    described_class.new(order).call
    item = pkg.reload.package_items.first
    expect(item.refunded_quantity).to eq(2)
    expect(item.fully_refunded?).to be(true)
    expect(pkg.package_items.count).to eq(1)  # not deleted
  end

  it "recomputes refunded_quantity (does not accumulate) across syncs" do
    pkg = build!
    order.update!(shopify_data: order.shopify_data.merge("refunds" => [ { "refund_line_items" => [ { "line_item_id" => 7001, "quantity" => 1 } ] } ]))
    described_class.new(order).call
    described_class.new(order).call  # same refund again
    expect(pkg.reload.package_items.first.refunded_quantity).to eq(1)
  end

  it "does not smart-update a refunded (terminal) package" do
    pkg = build!
    order.update!(financial_status: "refunded")
    described_class.new(order).call  # transitions to refunded
    order.update!(financial_status: "paid", shopify_data: order.shopify_data.merge("shipping_address" => { "city" => "LA" }))
    described_class.new(order).call
    expect(pkg.reload).to have_state(:refunded)
    expect(pkg.shipping_address_snapshot["city"]).not_to eq("LA")
  end
end
```

- [ ] **Step 2: Run — expect failure.** `bundle exec rspec spec/services/package_auto_builder_spec.rb -e "smart re-sync"` → FAIL.

- [ ] **Step 3: Implement smart_update in `do_call`**

Change `do_call` so that when an existing non-terminal package is present and the order is not fully refunded, it smart-updates:
```ruby
  def do_call
    return unless @store

    existing = @store.packages.find_by(order_id: @order.id)
    if fully_refunded?
      refund(existing) if existing
      return
    end

    if existing
      smart_update(existing) unless existing.refunded?
      return
    end

    return unless @store.packing_enabled?
    return unless eligible?

    build_package
  end
```
Add the smart_update method:
```ruby
  # Re-sync an existing, non-terminal package's snapshots from the latest order
  # data, honoring per-section override flags (2B-2's edits set them). Item
  # refunds are marked, never deleted.
  def smart_update(package)
    package.with_lock do
      unless package.address_overridden
        package.update!(shipping_address_snapshot: @order.shopify_data["shipping_address"] || {})
      end
      sync_items(package)
    end
  end

  def sync_items(package)
    refunds = refunded_quantities
    existing_by_li = package.package_items.index_by(&:order_line_item_id)

    @order.order_line_items.find_each do |li|
      item = existing_by_li[li.id]
      refunded = refunds[li.shopify_line_item_id] || 0
      if item
        attrs = { quantity: li.quantity, refunded_quantity: refunded }
        attrs.merge!(customs_attributes_for(li)) unless item.customs_overridden
        item.update!(attrs)
      else
        package.package_items.create!(
          customs_attributes_for(li).merge(
            product_variant_id: li.product_variant_id,
            order_line_item_id: li.id,
            sku: li.sku_at_sale,
            title: li.title_at_sale,
            quantity: li.quantity,
            refunded_quantity: refunded
          )
        )
      end
    end
  end
```
Note: `sync_items` updates `quantity` even for an item whose customs is overridden (override only protects the customs fields, per design — quantity/refund always reflect the order). A fully-refunded item keeps its row (marked via refunded_quantity), it is not deleted.

- [ ] **Step 4: Run — expect pass.** `bundle exec rspec spec/services/package_auto_builder_spec.rb` → PASS (build-time + smart re-sync + all existing 2A builder specs).

- [ ] **Step 5: Commit**
```bash
bin/rubocop app/services/package_auto_builder.rb
git add app/services/package_auto_builder.rb spec/services/package_auto_builder_spec.rb
git commit -m "feat(packing): smart re-sync of existing packages with per-section overrides and item refund flags"
```

---

### Task 4: Manual "sync orders" button (current store) on packing pages

**Files:**
- Modify: `config/routes.rb`, `app/controllers/packages_controller.rb`, `app/views/packages/index.html.erb`
- Modify: `config/locales/*.yml`
- Test: `spec/requests/packages_spec.rb`, `spec/system/packages_spec.rb`

**Interfaces:**
- Produces: `POST sync_packages_path` → enqueues `SyncAllShopifyOrdersJob` for the current store (or all visible if none selected), flashes a notice. Consumed by the list-page button.

- [ ] **Step 1: Route**

In `config/routes.rb`, extend the packages resource:
```ruby
    resources :packages, only: [ :index ] do
      post :sync, on: :collection
    end
```

- [ ] **Step 2: Controller action**

Add to `PackagesController`:
```ruby
  def sync
    stores = current_shopify_store ? [ current_shopify_store ] : visible_shopify_stores
    stores.each { |s| SyncAllShopifyOrdersJob.perform_later(s.id) }
    redirect_back fallback_location: packages_path, notice: t("packages.sync_enqueued")
  end
```
(The `authorize_page!` override already gates all actions on any packing permission, so `sync` is covered.)

- [ ] **Step 3: i18n** (all three locales) under `packages:`:
- en: `sync_orders: "Sync orders"`, `sync_enqueued: "Order sync queued for the selected store."`
- zh-TW: `sync_orders: "同步訂單"`, `sync_enqueued: "已排程當前店鋪的訂單同步。"`
- zh-CN: `sync_orders: "同步订单"`, `sync_enqueued: "已排程当前店铺的订单同步。"`

- [ ] **Step 4: Button in the view**

In `app/views/packages/index.html.erb`, add a top-right button (near the page title / above the table). Use `button_to` posting to `sync_packages_path`, preserving nothing else:
```erb
<div class="flex items-center justify-between mb-4">
  <h1 class="text-lg font-semibold text-gray-900"><%= t("packages.title", default: "Packages") %></h1>
  <%= button_to t("packages.sync_orders"), sync_packages_path, method: :post,
      class: "px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700" %>
</div>
```
(Match the existing page's heading structure — if `index.html.erb` already has a title element, integrate the button into that row rather than duplicating the heading.)

- [ ] **Step 5: Request spec** `spec/requests/packages_spec.rb`:
```ruby
describe "POST /packages/sync" do
  let(:user) { create(:user) }
  let(:store) { user.companies.first.shopify_stores.first || create(:shopify_store, user: user, company: user.companies.first) }

  it "enqueues a sync job for the selected store and redirects with a notice" do
    store # ensure exists
    sign_in user
    expect {
      post sync_packages_path
    }.to have_enqueued_job(SyncAllShopifyOrdersJob)
    expect(flash[:notice]).to be_present
  end

  it "denies a member without any packing permission" do
    member = create(:user)
    create(:membership, user: member, company: user.companies.first, role: :member, permissions: ["orders"], group: create(:group, company: user.companies.first))
    sign_in member
    patch switch_company_path(id: user.companies.first.id)
    post sync_packages_path
    expect(response).to redirect_to(authenticated_root_path)
  end
end
```
(Match how other request specs in this file build the signed-in user/store and enable `ActiveJob::TestHelper` / `have_enqueued_job` — check `spec/rails_helper.rb` for the ActiveJob test adapter; if `have_enqueued_job` isn't wired, assert via `SyncAllShopifyOrdersJob` enqueued count using the test adapter, following any existing job-enqueue spec in the repo.)

- [ ] **Step 6: System spec** `spec/system/packages_spec.rb`: the sync button is visible on the packing list; clicking it shows the flash notice.

- [ ] **Step 7: Run + commit**
```bash
bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb
bin/rubocop app/controllers/packages_controller.rb
git add config/routes.rb app/controllers/packages_controller.rb app/views/packages/index.html.erb config/locales spec
git commit -m "feat(packing): manual sync-orders button (current store) on packing pages"
```

---

### Task 5: Item refund warning on the list row

**Files:**
- Modify: `app/views/packages/_package_row.html.erb`
- Modify: `config/locales/*.yml`
- Test: `spec/requests/packages_spec.rb` (or system)

**Interfaces:**
- Consumes: `PackageItem#refunded_quantity`, `#fully_refunded?` (Task 1). Produces: a per-item warning badge on the list row.

- [ ] **Step 1: i18n** (all three locales) under `packages:`:
- en: `item_refunded: "Refunded %{n}/%{total}"`, `do_not_ship: "Do not ship"`
- zh-TW: `item_refunded: "已退款 %{n}/%{total}"`, `do_not_ship: "勿發"`
- zh-CN: `item_refunded: "已退款 %{n}/%{total}"`, `do_not_ship: "勿发"`

- [ ] **Step 2: Failing request spec**

Add to `spec/requests/packages_spec.rb` (a describe that builds a package with a refunded item and asserts the list body shows the warning):
```ruby
describe "item refund warnings on the list" do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }
  let(:store) { create(:shopify_store, user: user, company: company) }

  it "shows a refund badge and 'do not ship' for a fully-refunded item" do
    pkg = create(:package, shopify_store: store, aasm_state: "pending_review")
    create(:package_item, package: pkg, sku: "WP-1", quantity: 2, refunded_quantity: 2)
    sign_in user
    get packages_path(state: "pending_review")
    expect(response.body).to include(CGI.escapeHTML(I18n.t("packages.do_not_ship")))
    expect(response.body).to include("2/2")
  end

  it "shows a partial refund badge without do-not-ship" do
    pkg = create(:package, shopify_store: store, aasm_state: "pending_review")
    create(:package_item, package: pkg, sku: "WP-1", quantity: 3, refunded_quantity: 1)
    sign_in user
    get packages_path(state: "pending_review")
    expect(response.body).to include("1/3")
    expect(response.body).not_to include(CGI.escapeHTML(I18n.t("packages.do_not_ship")))
  end
end
```
(Adjust the package/store/user construction to match the file's existing helpers so `packages_path` is authorized and the store is visible.)

- [ ] **Step 3: Run — expect failure.** FAIL (no badge rendered).

- [ ] **Step 4: Implement in `_package_row.html.erb`**

In the items cell (where each `package.package_items` is rendered with `sku ×quantity title`), add after each item's text, when `item.refunded_quantity > 0`:
```erb
<% if item.refunded_quantity.positive? %>
  <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium <%= item.fully_refunded? ? 'bg-red-100 text-red-800' : 'bg-amber-100 text-amber-800' %>">
    <%= t("packages.item_refunded", n: item.refunded_quantity, total: item.quantity) %><% if item.fully_refunded? %> · <%= t("packages.do_not_ship") %><% end %>
  </span>
<% end %>
```
(Locate the exact loop variable name the partial uses for each item — the explore report shows items rendered as `sku ×quantity title`; use that same local.)

- [ ] **Step 5: Run — expect pass.** `bundle exec rspec spec/requests/packages_spec.rb -e "item refund warnings"` → PASS.

- [ ] **Step 6: System spec** — extend `spec/system/packages_spec.rb` to assert the "do not ship" badge renders for a fully-refunded item on the list.

- [ ] **Step 7: Commit**
```bash
git add app/views/packages/_package_row.html.erb config/locales spec
git commit -m "feat(packing): item refund warning + do-not-ship badge on package list"
```

---

## Verification (before PR)
- [ ] `bundle exec rspec` green, coverage ≥95%.
- [ ] `bin/rubocop`, `bin/brakeman --no-pager`, `bin/bundler-audit` clean.
- [ ] Manual: build a package; edit the order's Shopify address + re-sync → snapshot updates; set address_overridden via console + re-sync → snapshot preserved; add a refund to the order payload + re-sync → item shows the badge / "do not ship"; click the sync button → flash + job enqueued.
- [ ] PR into `staging`.

## Self-Review notes
- **Design coverage:** address jsonb snapshot + address_overridden (T1) ✓; per-item customs snapshot + customs_overridden + refunded_quantity (T1) ✓; build-time snapshots (T2) ✓; smart re-sync honoring overrides, item add/quantity update, refund mark-not-delete, terminal-package skip (T3) ✓; manual sync button current-store (T4) ✓; refund warning + do-not-ship badge (T5) ✓; i18n all locales per task ✓; system specs for the button + badge (T4/T5) ✓.
- **Scope boundary respected:** no detail page, no edit operations, no folding. Override flags created but only smart-re-sync READS them (nothing sets them in 2B-1 — 2B-2 does). Called out in Global Constraints.
- **Type consistency:** `shipping_address_snapshot`, `address_overridden`, `customs_*`, `customs_overridden`, `refunded_quantity`, `fully_refunded?`, `customs_attributes_for`, `refunded_quantities`, `smart_update`, `sync_items` — used consistently across tasks.
- **Known integration points:** the smart_update runs inside the existing `PackageAutoBuilder#call` (already exception-isolated + hooked into sync); refund parsing reads `order.shopify_data["refunds"]` (full payload stored by sync). The sync button reuses `SyncAllShopifyOrdersJob.perform_later(store_id)` (already per-store).
