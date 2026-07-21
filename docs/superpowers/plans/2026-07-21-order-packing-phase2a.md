# Order Packing Phase 2A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the packing-module foundation — a `Package` + `PackageItem` model with an AASM state machine, a per-store packing toggle + ID sequence, auto-creation of a "待審核" package when a paid/uncancelled/unrefunded order syncs, full-refund → 已退款, three packing permissions, and read-only per-status list pages under a "打包" sidebar group.

**Architecture:** Orders sync through `SyncAllOrdersService#sync_order`; a new `PackageAutoBuilder` service hooks in after each order upserts to create/refund packages. `Package` uses the `aasm` gem (newly added; the existing Ticket state machine stays hand-rolled). Read-only list pages mirror the Dianxiaomi layout (package-per-row) and reuse the existing store-scoping/pagination patterns from `ParcelsController`/`OrdersController`.

**Tech Stack:** Rails 8.1, PostgreSQL UUID PKs, aasm gem, Hotwire/Turbo, Tailwind, RSpec + FactoryBot.

## Global Constraints

- All table IDs use UUIDs (`id: :uuid`, `t.references ..., type: :uuid, foreign_key: true`).
- RSpec + FactoryBot, no fixtures; ≥95% line coverage. No mocks (there is no external boundary in 2A).
- Turbo-driven UI ships a system spec in the same commit.
- i18n keys in all three locales: `config/locales/en.yml`, `config/locales/zh-TW.yml`, `config/locales/zh-CN.yml`. New permission labels go under `invitations.permission_labels.<key>`.
- Route helpers take keyword ids under the `scope "(:locale)"` wrapper.
- Full-refund detection = `order.financial_status == "refunded"` (partial = `"partially_refunded"`, which does NOT count). Paid = `financial_status IN ('paid','partially_paid')`. Uncancelled = `order.shopify_data["cancelled_at"]` is nil.
- Never commit to `main`/`staging`; work on `feature/order-packing-phase2a` (already off `origin/staging`).
- Design: `docs/superpowers/specs/2026-07-21-order-packing-phase2a-design.md`. PRD: `.plan/PRD_order_packing.md`.
- 2A is READ-ONLY at the UI: NO operation buttons (審核/折包/申請/打單/發貨 are 2B/2C). List pages only display packages.

## File Structure

- `Gemfile` — add `gem "aasm"`
- `db/migrate/*_add_packing_fields_to_shopify_stores.rb` — toggle + prefix + start + seq (Task 1)
- `db/migrate/*_create_packages.rb`, `*_create_package_items.rb` (Task 2)
- `app/models/shopify_store.rb` — packing settings + lock validation (Task 1)
- `app/models/package.rb` — AASM state machine, package_code, number assignment (Task 2, 3)
- `app/models/package_item.rb` (Task 2)
- `app/services/package_auto_builder.rb` — create/refund on sync (Task 4)
- `app/services/sync_all_orders_service.rb` — hook the builder in (Task 4)
- `app/models/membership.rb`, `app/controllers/admin_controller.rb` — permissions (Task 5)
- `app/controllers/packages_controller.rb` — read-only status list pages (Task 6)
- `app/views/packages/*`, `app/views/shared/_sidebar.html.erb` — group + lists (Task 6)
- `app/views/shopify_stores/show.html.erb` + controller — store packing settings UI (Task 7)
- Factories + specs alongside each task.

---

### Task 1: Per-store packing settings (toggle, prefix, start, seq) + lock validation

**Files:**
- Create: `db/migrate/20260721130001_add_packing_fields_to_shopify_stores.rb`
- Modify: `app/models/shopify_store.rb`
- Test: `spec/models/shopify_store_spec.rb`

**Interfaces:**
- Produces: `ShopifyStore#packing_enabled` (bool), `#package_prefix`, `#package_number_start`, `#package_number_seq` (int); `#packing_settings_locked?` (true once the store has any package). Consumed by Tasks 4 (auto-build/seq), 7 (settings UI).

- [ ] **Step 1: Migration**
```ruby
class AddPackingFieldsToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :packing_enabled, :boolean, null: false, default: false
    add_column :shopify_stores, :package_prefix, :string
    add_column :shopify_stores, :package_number_start, :integer
    add_column :shopify_stores, :package_number_seq, :integer
  end
end
```
Run: `bin/rails db:migrate && bin/rails db:test:prepare`.

- [ ] **Step 2: Failing model spec**

Add to `spec/models/shopify_store_spec.rb`:
```ruby
describe "packing settings" do
  let(:store) { create(:shopify_store) }

  it "defaults packing_enabled to false" do
    expect(store.packing_enabled).to be(false)
  end

  it "requires prefix and start number when enabling packing" do
    store.packing_enabled = true
    expect(store).not_to be_valid
    expect(store.errors[:package_prefix]).to be_present
    expect(store.errors[:package_number_start]).to be_present
  end

  it "is valid when enabling with prefix and start" do
    store.assign_attributes(packing_enabled: true, package_prefix: "XMBDE", package_number_start: 2013094)
    expect(store).to be_valid
  end

  it "locks prefix/start once a package exists" do
    store.update!(packing_enabled: true, package_prefix: "XMBDE", package_number_start: 2013094)
    create(:package, shopify_store: store)
    store.reload.package_prefix = "OTHER"
    expect(store).not_to be_valid
    expect(store.errors[:package_prefix]).to be_present
  end

  it "does not lock other fields once a package exists" do
    store.update!(packing_enabled: true, package_prefix: "XMBDE", package_number_start: 1)
    create(:package, shopify_store: store)
    store.reload.name = "Renamed"
    expect(store).to be_valid
  end
end
```
(The `:package` factory arrives in Task 2; if running Task 1 alone, the last two examples fail on the missing factory — that is expected until Task 2. Implement the model logic now; those two go green after Task 2.)

- [ ] **Step 3: Run — expect failure.** `bundle exec rspec spec/models/shopify_store_spec.rb -e "packing settings"` → FAIL.

- [ ] **Step 4: Implement in `app/models/shopify_store.rb`**

Add associations + validations (place the `has_many :packages` near the other `has_many`, the validations after the existing `trustpilot_bcc_email` validation):
```ruby
  has_many :packages, dependent: :destroy

  validates :package_prefix, :package_number_start, presence: true, if: :packing_enabled?
  validates :package_number_start, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :packing_identity_locked_once_used

  def packing_settings_locked?
    packages.exists?
  end

  private

  def packing_identity_locked_once_used
    return unless persisted? && packing_settings_locked?
    if will_save_change_to_package_prefix? || will_save_change_to_package_number_start?
      errors.add(:package_prefix, :locked_after_first_package) if will_save_change_to_package_prefix?
      errors.add(:package_number_start, :locked_after_first_package) if will_save_change_to_package_number_start?
    end
  end
```
Add i18n for the two error messages (`en`/`zh-TW`/`zh-CN`) under `activerecord.errors.models.shopify_store.attributes.package_prefix.locked_after_first_package` and `.package_number_start.locked_after_first_package`:
- en: `"cannot be changed after the first package is created"`
- zh-TW: `"產生第一個包裹後即無法變更"`
- zh-CN: `"生成第一个包裹后即无法变更"`

- [ ] **Step 5: Run — the first three examples pass** (the two package-dependent ones pass after Task 2).
Run: `bundle exec rspec spec/models/shopify_store_spec.rb -e "packing settings"`

- [ ] **Step 6: Commit**
```bash
bin/rubocop app/models/shopify_store.rb
git add db/migrate app/models/shopify_store.rb config/locales db/schema.rb spec/models/shopify_store_spec.rb
git commit -m "feat(packing): per-store packing toggle, prefix, and number sequence with lock"
```

---

### Task 2: Package + PackageItem models + factories

**Files:**
- Create: `db/migrate/20260721130002_create_packages.rb`, `db/migrate/20260721130003_create_package_items.rb`
- Create: `app/models/package.rb`, `app/models/package_item.rb`
- Create: `spec/factories/packages.rb`, `spec/factories/package_items.rb`
- Test: `spec/models/package_spec.rb`, `spec/models/package_item_spec.rb`
- Modify: `Gemfile` (add aasm)

**Interfaces:**
- Produces: `Package` (belongs_to shopify_store, order; has_many package_items; `number` int, `aasm_state`, `application_status`, `held_from`, `note`, `logistics_channel_id`), `Package#package_code`; `PackageItem` (belongs_to package; sku/title/quantity). Consumed by Tasks 1, 3, 4, 6.

- [ ] **Step 1: Add aasm gem**

In `Gemfile`, add near the other model-layer gems:
```ruby
gem "aasm"
```
Run: `bundle install`. Expect `aasm` resolved in `Gemfile.lock`.

- [ ] **Step 2: Migrations**
```ruby
# 20260721130002_create_packages.rb
class CreatePackages < ActiveRecord::Migration[8.1]
  def change
    create_table :packages, id: :uuid do |t|
      t.references :shopify_store, type: :uuid, null: false, foreign_key: true
      t.references :order, type: :uuid, null: false, foreign_key: true
      t.references :logistics_channel, type: :uuid, null: true, foreign_key: true
      t.string  :aasm_state, null: false
      t.string  :application_status, null: false, default: "none"
      t.string  :held_from
      t.integer :number, null: false
      t.text    :note
      t.timestamps
    end
    add_index :packages, :order_id, unique: true, name: "index_packages_on_order_id_unique"
    add_index :packages, [ :shopify_store_id, :number ], unique: true
    add_index :packages, [ :shopify_store_id, :aasm_state ]
  end
end
```
```ruby
# 20260721130003_create_package_items.rb
class CreatePackageItems < ActiveRecord::Migration[8.1]
  def change
    create_table :package_items, id: :uuid do |t|
      t.references :package, type: :uuid, null: false, foreign_key: true
      t.references :product_variant, type: :uuid, null: true, foreign_key: true
      t.references :order_line_item, type: :uuid, null: true, foreign_key: true
      t.string  :sku
      t.string  :title
      t.integer :quantity, null: false
      t.timestamps
    end
  end
end
```
Note: `packages.order_id` has a UNIQUE index but is NOT `add_reference ... index: {unique}`; the `t.references` above adds a plain index, then we add the unique one explicitly (drop the plain one is unnecessary — Rails' `t.references` index + our named unique index coexist; to avoid a duplicate, pass `index: false` on the `t.references :order` line). Use:
```ruby
      t.references :order, type: :uuid, null: false, foreign_key: true, index: false
```
Run: `bin/rails db:migrate && bin/rails db:test:prepare`.

- [ ] **Step 3: Models (minimal, state machine comes in Task 3)**

`app/models/package_item.rb`:
```ruby
class PackageItem < ApplicationRecord
  belongs_to :package
  belongs_to :product_variant, optional: true
  belongs_to :order_line_item, optional: true

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
end
```
`app/models/package.rb` (state machine added in Task 3; here just structure + package_code):
```ruby
class Package < ApplicationRecord
  belongs_to :shopify_store
  belongs_to :order
  belongs_to :logistics_channel, optional: true
  has_many :package_items, dependent: :destroy

  validates :number, presence: true, uniqueness: { scope: :shopify_store_id }

  # e.g. "XMBDE2013094" — prefix + number zero-padded to at least 7 digits.
  def package_code
    "#{shopify_store.package_prefix}#{number.to_s.rjust(7, '0')}"
  end
end
```

- [ ] **Step 4: Factories**
```ruby
# spec/factories/packages.rb
FactoryBot.define do
  factory :package do
    shopify_store
    order { association(:order, shopify_store: shopify_store) }
    sequence(:number) { |n| n }
    aasm_state { "pending_review" }
    application_status { "none" }
  end
end
# spec/factories/package_items.rb
FactoryBot.define do
  factory :package_item do
    package
    sku { "SKU-1" }
    title { "Test item" }
    quantity { 1 }
  end
end
```

- [ ] **Step 5: Specs**

`spec/models/package_spec.rb`:
```ruby
require "rails_helper"
RSpec.describe Package do
  it "builds a package_code from the store prefix and a 7-digit number" do
    store = create(:shopify_store, package_prefix: "XMBDE", package_number_start: 1)
    pkg = create(:package, shopify_store: store, number: 2013094)
    expect(pkg.package_code).to eq("XMBDE2013094")
  end

  it "pads numbers shorter than 7 digits" do
    store = create(:shopify_store, package_prefix: "AB")
    pkg = create(:package, shopify_store: store, number: 42)
    expect(pkg.package_code).to eq("AB0000042")
  end

  it "enforces unique number per store" do
    store = create(:shopify_store)
    create(:package, shopify_store: store, number: 5)
    dup = build(:package, shopify_store: store, number: 5)
    expect(dup).not_to be_valid
  end
end
```
`spec/models/package_item_spec.rb`:
```ruby
require "rails_helper"
RSpec.describe PackageItem do
  it "requires a positive integer quantity" do
    expect(build(:package_item, quantity: 0)).not_to be_valid
    expect(build(:package_item, quantity: 2)).to be_valid
  end
end
```

- [ ] **Step 6: Run + verify Task 1's package-dependent examples now pass**
```bash
bundle exec rspec spec/models/package_spec.rb spec/models/package_item_spec.rb spec/models/shopify_store_spec.rb
```
Expect all green (including Task 1's "locks prefix/start once a package exists").

- [ ] **Step 7: Commit**
```bash
bin/rubocop app/models/package.rb app/models/package_item.rb
git add Gemfile Gemfile.lock db/migrate app/models/package.rb app/models/package_item.rb spec/factories/packages.rb spec/factories/package_items.rb spec/models/package_spec.rb spec/models/package_item_spec.rb db/schema.rb
git commit -m "feat(packing): Package + PackageItem models with aasm gem"
```

---

### Task 3: Package AASM state machine

**Files:**
- Modify: `app/models/package.rb`
- Test: `spec/models/package_spec.rb`

**Interfaces:**
- Produces: AASM states `pending_review` (initial), `pending_process`, `applying_tracking`, `pending_label`, `shipped`, `refunded`, `held`; events `submit_review`, `apply_tracking`, `to_label`, `ship`, `back_to_review`, `back_to_process`, `hold`, `unhold`, `refund!`. `held_from` records the pre-hold state. Consumed by Task 4 (refund!) and 2B/2C (all transitions).

- [ ] **Step 1: Failing state-machine spec**

Add to `spec/models/package_spec.rb`:
```ruby
describe "state machine" do
  let(:pkg) { create(:package) }

  it "starts in pending_review" do
    expect(pkg).to have_state(:pending_review)  # aasm rspec matcher
  end

  it "walks the happy path review→process→applying→label→shipped" do
    pkg.submit_review!
    expect(pkg).to have_state(:pending_process)
    pkg.apply_tracking!
    expect(pkg).to have_state(:applying_tracking)
    pkg.to_label!
    expect(pkg).to have_state(:pending_label)
    pkg.ship!
    expect(pkg).to have_state(:shipped)
  end

  it "rejects skipping states" do
    expect(pkg).not_to allow_event(:ship)
    expect { pkg.ship! }.to raise_error(AASM::InvalidTransition)
  end

  it "records held_from on hold and restores it on unhold" do
    pkg.submit_review!  # now pending_process
    pkg.hold!
    expect(pkg).to have_state(:held)
    expect(pkg.held_from).to eq("pending_process")
    pkg.unhold!
    expect(pkg).to have_state(:pending_process)
    expect(pkg.held_from).to be_nil
  end

  it "can refund from any active state including shipped, and refund is terminal" do
    pkg.submit_review!; pkg.apply_tracking!; pkg.to_label!; pkg.ship!
    pkg.refund!
    expect(pkg).to have_state(:refunded)
    expect(pkg).not_to allow_event(:submit_review)
  end

  it "can back_to_process from applying_tracking" do
    pkg.submit_review!; pkg.apply_tracking!
    pkg.back_to_process!
    expect(pkg).to have_state(:pending_process)
  end
end
```
Ensure the aasm rspec matchers load: add `require "aasm/rspec"` in `spec/rails_helper.rb` (or a support file). If `have_state`/`allow_event` aren't available, assert via `pkg.pending_review?` / `expect { }.to raise_error(AASM::InvalidTransition)` instead — but prefer the matchers.

- [ ] **Step 2: Run — expect failure.** `bundle exec rspec spec/models/package_spec.rb -e "state machine"` → FAIL.

- [ ] **Step 3: Implement the state machine in `app/models/package.rb`**

Add `include AASM` and the machine (keep the existing associations/validations/package_code):
```ruby
  include AASM

  aasm column: :aasm_state do
    state :pending_review, initial: true
    state :pending_process
    state :applying_tracking
    state :pending_label
    state :shipped
    state :refunded
    state :held

    event :submit_review do
      transitions from: :pending_review, to: :pending_process
    end
    event :apply_tracking do
      transitions from: :pending_process, to: :applying_tracking
    end
    event :to_label do
      transitions from: :applying_tracking, to: :pending_label
    end
    event :ship do
      transitions from: :pending_label, to: :shipped
    end
    event :back_to_review do
      transitions from: :pending_process, to: :pending_review
    end
    event :back_to_process do
      transitions from: [ :applying_tracking, :pending_label ], to: :pending_process
    end
    event :hold do
      before { self.held_from = aasm_state }
      transitions from: [ :pending_review, :pending_process, :applying_tracking, :pending_label ], to: :held
    end
    event :unhold do
      transitions from: :held, to: :pending_review, guard: -> { held_from == "pending_review" }
      transitions from: :held, to: :pending_process, guard: -> { held_from == "pending_process" }
      transitions from: :held, to: :applying_tracking, guard: -> { held_from == "applying_tracking" }
      transitions from: :held, to: :pending_label, guard: -> { held_from == "pending_label" }
      after { self.held_from = nil }
    end
    event :refund do
      transitions from: [ :pending_review, :pending_process, :applying_tracking, :pending_label, :shipped ], to: :refunded
    end
  end
```
Note: aasm's `!`-suffixed event methods persist (`save`). `refund!` is used by Task 4.

- [ ] **Step 4: Run — expect pass.** `bundle exec rspec spec/models/package_spec.rb` → PASS.

- [ ] **Step 5: Commit**
```bash
bin/rubocop app/models/package.rb spec/rails_helper.rb
git add app/models/package.rb spec/models/package_spec.rb spec/rails_helper.rb
git commit -m "feat(packing): Package AASM state machine (review→shipped, hold/unhold, refund)"
```

---

### Task 4: Auto-build packages on order sync + full-refund handling

**Files:**
- Create: `app/services/package_auto_builder.rb`
- Modify: `app/services/sync_all_orders_service.rb`
- Test: `spec/services/package_auto_builder_spec.rb`

**Interfaces:**
- Consumes: `ShopifyStore` packing settings + seq (Task 1), `Package`/`PackageItem` (Task 2), `Package#refund!` (Task 3).
- Produces: `PackageAutoBuilder.new(order).call` — creates a `pending_review` package (assigning `number` under a store row lock, copying line items) when eligible, or refunds the existing package when the order just became fully refunded.

- [ ] **Step 1: Failing service spec**

`spec/services/package_auto_builder_spec.rb`:
```ruby
require "rails_helper"
RSpec.describe PackageAutoBuilder do
  let(:store) { create(:shopify_store, packing_enabled: true, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:order) do
    o = create(:order, shopify_store: store, financial_status: "paid")
    create(:order_line_item, order: o, sku_at_sale: "WP10155-L", title_at_sale: "Puzzle", quantity: 2)
    o
  end

  it "creates a pending_review package with the store's starting number and copied items" do
    described_class.new(order).call
    pkg = store.packages.find_by(order: order)
    expect(pkg).to be_present
    expect(pkg).to have_state(:pending_review)
    expect(pkg.number).to eq(2013094)
    expect(pkg.package_items.pluck(:sku, :quantity)).to contain_exactly([ "WP10155-L", 2 ])
    expect(store.reload.package_number_seq).to eq(2013095)
  end

  it "increments the sequence for the next package" do
    described_class.new(order).call
    order2 = create(:order, shopify_store: store, financial_status: "paid")
    described_class.new(order2).call
    expect(store.packages.find_by(order: order2).number).to eq(2013095)
  end

  it "is idempotent — a second call does not create a duplicate" do
    described_class.new(order).call
    expect { described_class.new(order).call }.not_to change { Package.count }
  end

  it "does not build when packing is disabled" do
    store.update_columns(packing_enabled: false)
    described_class.new(order).call
    expect(store.packages.count).to eq(0)
  end

  it "does not build for an unpaid order" do
    order.update!(financial_status: "pending")
    described_class.new(order).call
    expect(store.packages.count).to eq(0)
  end

  it "does not build for a cancelled order" do
    order.update!(shopify_data: { "cancelled_at" => "2026-07-20T00:00:00Z" })
    described_class.new(order).call
    expect(store.packages.count).to eq(0)
  end

  it "does not build for a fully refunded order" do
    order.update!(financial_status: "refunded")
    described_class.new(order).call
    expect(store.packages.count).to eq(0)
  end

  it "refunds an existing package when the order is fully refunded" do
    described_class.new(order).call
    pkg = store.packages.find_by(order: order)
    order.update!(financial_status: "refunded")
    described_class.new(order).call
    expect(pkg.reload).to have_state(:refunded)
  end

  it "does not refund on a partial refund" do
    described_class.new(order).call
    pkg = store.packages.find_by(order: order)
    order.update!(financial_status: "partially_refunded")
    described_class.new(order).call
    expect(pkg.reload).not_to have_state(:refunded)
  end
end
```

- [ ] **Step 2: Run — expect failure.** `bundle exec rspec spec/services/package_auto_builder_spec.rb` → FAIL (no PackageAutoBuilder).

- [ ] **Step 3: Implement `app/services/package_auto_builder.rb`**
```ruby
# Builds/refunds a Package for an order as it syncs. Called from
# SyncAllOrdersService#sync_order after the order is upserted.
class PackageAutoBuilder
  PAID_STATUSES = %w[paid partially_paid].freeze

  def initialize(order)
    @order = order
    @store = order.shopify_store
  end

  def call
    return unless @store&.packing_enabled?

    existing = @store.packages.find_by(order_id: @order.id)
    if fully_refunded?
      refund(existing) if existing
      return
    end
    return if existing
    return unless eligible?

    build_package
  end

  private

  def fully_refunded?
    @order.financial_status == "refunded"
  end

  def cancelled?
    @order.shopify_data["cancelled_at"].present?
  end

  def eligible?
    PAID_STATUSES.include?(@order.financial_status) && !cancelled?
  end

  def refund(package)
    package.refund! unless package.refunded?
  end

  def build_package
    number = next_number
    Package.transaction do
      package = @store.packages.create!(order: @order, number: number)
      @order.order_line_items.find_each do |li|
        package.package_items.create!(
          product_variant_id: li.product_variant_id,
          order_line_item_id: li.id,
          sku: li.sku_at_sale,
          title: li.title_at_sale,
          quantity: li.quantity
        )
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # A concurrent sync already built it; safe to ignore (order_id is unique).
    nil
  end

  # Row-locked sequence: continuous, no gaps.
  def next_number
    @store.with_lock do
      seq = @store.package_number_seq || @store.package_number_start
      @store.update!(package_number_seq: seq + 1)
      seq
    end
  end
end
```

- [ ] **Step 4: Run — expect pass.** `bundle exec rspec spec/services/package_auto_builder_spec.rb` → PASS.

- [ ] **Step 5: Hook into the sync flow**

In `app/services/sync_all_orders_service.rb#sync_order`, after the order is saved and line items synced (right before/after `trigger_email_workflows`), add:
```ruby
    PackageAutoBuilder.new(order).call
```
(Place it after `sync_line_items(order, shopify_order)` so the copied items exist. It must run for both new and updated orders — updated because a later sync is how a refund is detected.)

- [ ] **Step 6: Integration spec — sync triggers the builder**

Add to `spec/services/sync_all_orders_service_spec.rb` (or the builder spec) a test that runs a real `sync_single_order` with a paid order payload on a packing-enabled store and asserts a package appears. Reuse the existing sync spec's payload-building helpers; if the existing sync spec stubs Shopify, follow that pattern. Assert `store.packages.count` becomes 1.

- [ ] **Step 7: Run + commit**
```bash
bundle exec rspec spec/services/package_auto_builder_spec.rb spec/services/sync_all_orders_service_spec.rb
bin/rubocop app/services/package_auto_builder.rb app/services/sync_all_orders_service.rb
git add app/services/package_auto_builder.rb app/services/sync_all_orders_service.rb spec/services
git commit -m "feat(packing): auto-build packages on order sync; full-refund transitions to refunded"
```

---

### Task 5: Three packing permissions

**Files:**
- Modify: `app/models/membership.rb`, `app/controllers/admin_controller.rb`
- Modify: `config/locales/*.yml`
- Test: `spec/models/membership_spec.rb`

**Interfaces:**
- Produces: `package_review`, `package_process`, `package_shipping` permissions in `AVAILABLE_PERMISSIONS`. `PERMISSION_KEY_MAP` maps the `packages` controller so any single packing permission grants list access (implemented in Task 6's controller, not via the single-key map). Consumed by Task 6.

- [ ] **Step 1: Add permissions**

`app/models/membership.rb` — append to `AVAILABLE_PERMISSIONS`:
```ruby
  AVAILABLE_PERMISSIONS = %w[
    orders shipments tickets ad_campaigns
    shopify_stores ad_accounts email_accounts
    shipping_reminder_rules parcels products
    logistics_channels
    package_review package_process package_shipping
  ].freeze
```
Add a helper for "has any packing permission":
```ruby
  PACKING_PERMISSIONS = %w[package_review package_process package_shipping].freeze

  def any_packing_permission?
    owner? || PACKING_PERMISSIONS.any? { |p| permissions.include?(p) }
  end
```

- [ ] **Step 2: i18n labels (all three locales)** under `invitations.permission_labels`:
- en: `package_review: "Package Review"`, `package_process: "Package Processing"`, `package_shipping: "Package Labeling & Shipping"`
- zh-TW: `package_review: "包裹審核"`, `package_process: "包裹處理"`, `package_shipping: "包裹打單與發貨"`
- zh-CN: `package_review: "包裹审核"`, `package_process: "包裹处理"`, `package_shipping: "包裹打单与发货"`

- [ ] **Step 3: Spec** `spec/models/membership_spec.rb`:
```ruby
describe "#any_packing_permission?" do
  let(:company) { create(:company) }
  it "is true for an owner" do
    m = create(:membership, company: company, role: :owner)
    expect(m.any_packing_permission?).to be(true)
  end
  it "is true for a member with any packing permission" do
    m = create(:membership, company: company, role: :member, permissions: ["package_process"], group: create(:group, company: company))
    expect(m.any_packing_permission?).to be(true)
  end
  it "is false for a member with no packing permission" do
    m = create(:membership, company: company, role: :member, permissions: ["orders"], group: create(:group, company: company))
    expect(m.any_packing_permission?).to be(false)
  end
end
```
(Match the membership factory's owner/member/group requirements — check `spec/factories/memberships.rb` and mirror how existing membership specs build members.)

- [ ] **Step 4: Run + commit**
```bash
bundle exec rspec spec/models/membership_spec.rb
bin/rubocop app/models/membership.rb
git add app/models/membership.rb app/controllers/admin_controller.rb config/locales spec/models/membership_spec.rb
git commit -m "feat(packing): package_review/process/shipping permissions"
```

---

### Task 6: Packing sidebar group + read-only per-status list pages

**Files:**
- Create: `app/controllers/packages_controller.rb`
- Create: `app/views/packages/index.html.erb`, `app/views/packages/_package_row.html.erb`
- Modify: `app/views/shared/_sidebar.html.erb`, `config/routes.rb`, `config/locales/*.yml`
- Test: `spec/requests/packages_spec.rb`, `spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: `Package`/`PackageItem` (Task 2/3), `any_packing_permission?` (Task 5), store scoping (`visible_shopify_stores`).
- Produces: `packages_path(state:)` list pages per status with counts.

- [ ] **Step 1: Route**

In `config/routes.rb`, inside the authenticated `scope "(:locale)"` block:
```ruby
    resources :packages, only: [ :index ]
```
(A single index that filters by a `state` param renders each status page; the sidebar links pass `state:`.)

- [ ] **Step 2: Controller** `app/controllers/packages_controller.rb`

Mirror `OrdersController`'s store-scoping + pagination. Gate on ANY packing permission (override the single-key check):
```ruby
class PackagesController < AdminController
  PER_PAGE = 50
  STATES = %w[pending_review pending_process applying_tracking pending_label shipped refunded held].freeze

  def index
    @state = STATES.include?(params[:state]) ? params[:state] : "pending_review"
    scope = scoped_packages.where(aasm_state: @state)
    scope = scope.where(application_status: params[:application_status]) if @state == "applying_tracking" && params[:application_status].present?
    @counts = scoped_packages.group(:aasm_state).count
    @page = [ params[:page].to_i, 1 ].max
    @total_count = scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0
    @packages = scope.includes(:order, :package_items, :shopify_store)
                     .order(created_at: :desc)
                     .offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  private

  def authorize_page!
    return if current_membership&.any_packing_permission?
    redirect_to authenticated_root_path, alert: t("companies.no_permission")
  end

  def scoped_packages
    Package.where(shopify_store_id: visible_shopify_stores.select(:id))
  end
end
```
(Overriding `authorize_page!` here replaces `AdminController`'s single-key gate for this controller — that is the "any packing permission" requirement. Confirm `AdminController#authorize_page!` is a `before_action` that a subclass method override replaces; if the before_action references the method by symbol, the override wins.)

- [ ] **Step 3: Views** — `index.html.erb` renders a status header, a package-per-row table (reuse the Dianxiaomi columns: package_code as row header, then items sku×qty, order total, destination country, order name, timestamps, logistics method, status), pagination, and (for `applying_tracking`) the 申請中/成功/失敗 sub-tabs linking with `application_status`. `_package_row.html.erb` renders one package with its items. Follow the styling of `app/views/parcels/index.html.erb`. Destination country can use `order.shopify_data.dig("shipping_address","country_code")`.

- [ ] **Step 4: Sidebar group** — in `app/views/shared/_sidebar.html.erb`, add a "打包" nav-group (mirror the Products group structure at L157-186) gated by `current_membership&.any_packing_permission?`. Children link to `packages_path(state: "...")` for each of the 7 states, each showing a count badge from a helper that counts `Package.where(shopify_store_id: visible_shopify_stores.select(:id)).group(:aasm_state).count` (compute once in a helper method to avoid N queries). Group the first five under the main list and 已退款/已擱置 under an "其他" visual subsection. Add `packages` to the nav-group's active-controller whitelist. i18n `nav.packing` + each state label in all three locales.

- [ ] **Step 5: Request specs** `spec/requests/packages_spec.rb`:
  - a member with `package_review` (or any packing perm) gets 200 on `packages_path`; a member with only `orders` is redirected.
  - the list shows only the requested `state`'s packages, scoped to the company's stores (cross-company isolation: a package in company B's store is not shown to company A).
  - `applying_tracking` + `application_status=pending` filters correctly.

- [ ] **Step 6: System spec** `spec/system/packages_spec.rb` (`:js`): the 打包 group expands; clicking 待審核 shows its packages; counts render.

- [ ] **Step 7: Run + commit**
```bash
bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb
bin/rubocop app/controllers/packages_controller.rb
git add app/controllers/packages_controller.rb app/views/packages app/views/shared/_sidebar.html.erb config/routes.rb config/locales spec
git commit -m "feat(packing): 打包 sidebar group and read-only per-status package lists"
```

---

### Task 7: Store packing settings UI

**Files:**
- Modify: `app/views/shopify_stores/show.html.erb`, `app/controllers/shopify_stores_controller.rb`
- Modify: `config/locales/*.yml`
- Test: `spec/requests/shopify_stores_spec.rb`, `spec/system/shopify_stores_spec.rb`

**Interfaces:**
- Consumes: `ShopifyStore` packing settings + `packing_settings_locked?` (Task 1).

- [ ] **Step 1: Controller update branch** — in `ShopifyStoresController#update`, add a branch (mirroring the existing `trustpilot_bcc_email` / `cost_fx_rate` branches) that permits `:packing_enabled, :package_prefix, :package_number_start` (owner-gated), and on validation failure re-renders with the error (the lock validation from Task 1 produces the error when prefix/start is changed after packages exist). Add `shopify_store_packing_params` permitting those three.

- [ ] **Step 2: Settings card** — in `app/views/shopify_stores/show.html.erb`, add a card (mirror the `trustpilot_bcc` card): a checkbox for `packing_enabled`, text inputs for `package_prefix` and `package_number_start`. When `@shopify_store.packing_settings_locked?`, render prefix/start as read-only (disabled inputs + a note), matching the design's lock rule. Owner-only editable, non-owner read-only (mirror existing cards). i18n all three locales for labels + hint (explain the lock).

- [ ] **Step 3: Request specs** `spec/requests/shopify_stores_spec.rb`:
  - owner enables packing with prefix+start → saved.
  - owner enabling without prefix → rejected (flash/validation).
  - after a package exists, owner changing prefix → rejected (locked).

- [ ] **Step 4: System spec** — visiting a store with packages shows prefix/start as read-only.

- [ ] **Step 5: Run + commit**
```bash
bundle exec rspec spec/requests/shopify_stores_spec.rb spec/system/shopify_stores_spec.rb
bin/rubocop app/controllers/shopify_stores_controller.rb
git add app/controllers/shopify_stores_controller.rb app/views/shopify_stores/show.html.erb config/locales spec
git commit -m "feat(packing): store settings UI for packing toggle, prefix, and start number"
```

---

## Verification (before PR)
- [ ] `bundle exec rspec` green, coverage ≥95%.
- [ ] `bin/rubocop`, `bin/brakeman --no-pager`, `bin/bundler-audit` clean.
- [ ] Manual: enable packing on a store with a prefix+start; sync a paid order → a 待審核 package appears with the right code/number/items; sidebar counts update; a full refund moves it to 已退款; prefix locks after the first package.
- [ ] PR into `staging`.

## Self-Review notes
- **Spec coverage:** per-store settings + lock (T1) ✓; Package/PackageItem + package_code + aasm gem (T2) ✓; state machine incl hold/unhold/refund-terminal (T3) ✓; auto-build eligibility + seq + idempotency + refund detection + sync hook (T4) ✓; three permissions + any-packing helper (T5) ✓; sidebar group + read-only per-status lists + counts + cross-company isolation (T6) ✓; store settings UI + lock read-only (T7) ✓; i18n all locales per task ✓; system specs for Turbo UIs (T6/T7) ✓.
- **Design coverage:** `application_status` column + applying_tracking sub-tabs (T2 col, T6 tabs) ✓; held_from + restore (T3) ✓; full-refund incl shipped→refunded, partial ignored (T3/T4) ✓; no-backtrack / paid+uncancelled+unrefunded eligibility (T4) ✓; read-only 2A (no operation buttons — T6) ✓.
- **Type consistency:** `aasm_state`, `application_status`, `held_from`, `number`, `package_code`, `PackageAutoBuilder.new(order).call`, `any_packing_permission?`, states list — used consistently across tasks.
- **Deferred to 2B/2C (called out):** operation buttons; logistics assignment writes; createOrder/label/ship; unhold UI. 2A wires the state machine + columns they'll use.
- **Known integration risk:** `SyncAllOrdersService` refund detection relies on a later sync re-running the builder for an already-synced order — the hook runs on every sync (new and updated), which is why Task 4 Step 5 places the call unconditionally.
