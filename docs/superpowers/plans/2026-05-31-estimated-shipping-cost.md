# Estimated Shipping Cost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add estimated shipping cost (computed from versioned, company-level rate cards) into the order cost stack so the dashboard reports an accurate net margin.

**Architecture:** Two new tables model rate cards — `shipping_rate_card_versions` (one named rate update per country × service, with effective dates) owning many `shipping_rate_card_rates` (weight bands). A pure-function `ShippingCostCalculator` looks up the newest applicable version for an order's date, finds the matching weight band, converts CNY → store currency via `cost_fx_rate`, and the result is snapshotted (frozen) onto `orders.estimated_shipping_cost` at sync time. A sibling `orders.actual_shipping_cost` column is reserved for a future carrier-invoice importer; the dashboard prefers `actual` and falls back to `estimated` via `COALESCE`. Owner-only inline-editing admin UI manages the rate cards.

**Tech Stack:** Rails 8.1, PostgreSQL (UUID PKs), Hotwire (Turbo Streams + Stimulus), Importmap, Tailwind, RSpec + FactoryBot.

**Spec:** `docs/superpowers/specs/2026-05-31-shipping-cost-and-net-margin-design.md`

**Conventions confirmed from the codebase (do not deviate):**
- New tables: `create_table :x, id: :uuid, default: -> { "gen_random_uuid()" }`; FK columns `t.uuid`; explicit `add_foreign_key`; named indexes.
- Owner gate is inline in each action: `current_membership&.owner?` (there is no shared `require_owner!` in `AdminController` — each controller defines its own private helper, mirroring `CompaniesController`).
- Page-level authorization uses `AdminController::PERMISSION_KEY_MAP` (controller name → permission string).
- Cost values: `variant.unit_cost` and rate-card CNY amounts are in CNY; store-currency value = `cny / store.cost_fx_rate` (where `cost_fx_rate` = CNY per 1 store currency).
- Tests: RSpec + FactoryBot, no mocks, hit the real DB. Owner is `create(:user)` (factory auto-creates their company + owner membership). Non-owner = a second user with a `:member` membership in the owner's company, activated via `sign_in member_user; patch switch_company_path(id: company.id)`.

---

## File Structure

**Migrations (new):**
- `db/migrate/20260531120001_create_shipping_rate_card_versions.rb`
- `db/migrate/20260531120002_create_shipping_rate_card_rates.rb`
- `db/migrate/20260531120003_add_default_service_type_to_shopify_stores.rb`
- `db/migrate/20260531120004_add_shipping_costs_to_orders.rb`

**Models (new):**
- `app/models/shipping_rate_card_version.rb`
- `app/models/shipping_rate_card_rate.rb`

**Models (modified):** `app/models/company.rb`, `app/models/order.rb`

**Services (new):** `app/services/shipping_cost_calculator.rb`
**Services (modified):** `app/services/sync_all_orders_service.rb`, `app/services/backfill_order_line_items_service.rb`, `app/services/dashboard_metrics_service.rb`

**Controllers (new):** `app/controllers/shipping_rate_card_versions_controller.rb`, `app/controllers/shipping_rate_card_rates_controller.rb`
**Controllers (modified):** `app/controllers/shopify_stores_controller.rb`, `app/controllers/admin_controller.rb`

**Views (new):** `app/views/shipping_rate_card_versions/` (`index.html.erb`, `_new_version_form.html.erb`, `_version.html.erb`, `update.turbo_stream.erb`) and `app/views/shipping_rate_card_rates/` (`_rate.html.erb`, `update.turbo_stream.erb`)
**Views (modified):** `app/views/shopify_stores/show.html.erb`, `app/views/dashboard/show.html.erb`

**JS (modified):** `app/javascript/controllers/cell_edit_controller.js`
**Config (modified):** `config/routes.rb`, `config/locales/en.yml`, `config/locales/zh-CN.yml`, `config/locales/zh-TW.yml`
**Factories (new):** `spec/factories/shipping_rate_card_versions.rb`, `spec/factories/shipping_rate_card_rates.rb`

---

## Task 1: Database migrations

**Files:**
- Create: `db/migrate/20260531120001_create_shipping_rate_card_versions.rb`
- Create: `db/migrate/20260531120002_create_shipping_rate_card_rates.rb`
- Create: `db/migrate/20260531120003_add_default_service_type_to_shopify_stores.rb`
- Create: `db/migrate/20260531120004_add_shipping_costs_to_orders.rb`

- [ ] **Step 1: Write the versions-table migration**

`db/migrate/20260531120001_create_shipping_rate_card_versions.rb`:

```ruby
class CreateShippingRateCardVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_rate_card_versions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid   :company_id, null: false
      t.string :name, null: false
      t.string :country_code, null: false
      t.string :service_type, null: false
      t.date   :effective_from, null: false
      t.date   :effective_to
      t.timestamps
    end
    add_index :shipping_rate_card_versions,
              [ :company_id, :country_code, :service_type, :effective_from ],
              name: "idx_rate_versions_lookup"
    add_foreign_key :shipping_rate_card_versions, :companies
  end
end
```

- [ ] **Step 2: Write the rates-table migration**

`db/migrate/20260531120002_create_shipping_rate_card_rates.rb`:

```ruby
class CreateShippingRateCardRates < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_rate_card_rates, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    :version_id, null: false
      t.decimal :weight_min_kg,   precision: 8,  scale: 3, null: false
      t.decimal :weight_max_kg,   precision: 8,  scale: 3, null: false
      t.decimal :per_kg_rate_cny, precision: 10, scale: 2, null: false
      t.decimal :flat_fee_cny,    precision: 10, scale: 2, default: 0, null: false
      t.timestamps
    end
    add_index :shipping_rate_card_rates, :version_id
    add_foreign_key :shipping_rate_card_rates, :shipping_rate_card_versions, column: :version_id
  end
end
```

- [ ] **Step 3: Write the shopify_stores column migration**

`db/migrate/20260531120003_add_default_service_type_to_shopify_stores.rb`:

```ruby
class AddDefaultServiceTypeToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :default_service_type, :string
  end
end
```

- [ ] **Step 4: Write the orders columns migration**

`db/migrate/20260531120004_add_shipping_costs_to_orders.rb`:

```ruby
class AddShippingCostsToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :estimated_shipping_cost, :decimal, precision: 10, scale: 2
    add_column :orders, :actual_shipping_cost,    :decimal, precision: 10, scale: 2
  end
end
```

- [ ] **Step 5: Run the migrations**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: 4 migrations run; `db/schema.rb` updated with both new tables and the new columns; no errors.

- [ ] **Step 6: Verify schema**

Run: `grep -E "shipping_rate_card_versions|shipping_rate_card_rates|default_service_type|estimated_shipping_cost|actual_shipping_cost" db/schema.rb`
Expected: all five identifiers present.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260531120001_create_shipping_rate_card_versions.rb \
        db/migrate/20260531120002_create_shipping_rate_card_rates.rb \
        db/migrate/20260531120003_add_default_service_type_to_shopify_stores.rb \
        db/migrate/20260531120004_add_shipping_costs_to_orders.rb \
        db/schema.rb
git commit -m "feat: add shipping rate card + order shipping cost schema"
```

---

## Task 2: `ShippingRateCardVersion` model

**Files:**
- Create: `app/models/shipping_rate_card_version.rb`
- Create: `spec/factories/shipping_rate_card_versions.rb`
- Test: `spec/models/shipping_rate_card_version_spec.rb`

- [ ] **Step 1: Write the factory**

`spec/factories/shipping_rate_card_versions.rb`:

```ruby
FactoryBot.define do
  factory :shipping_rate_card_version do
    company
    sequence(:name) { |n| "Rate Version #{n}" }
    country_code { "US" }
    service_type { "standard_with_battery" }
    effective_from { Date.new(2026, 1, 1) }
    effective_to { nil }
  end
end
```

- [ ] **Step 2: Write the failing model spec**

`spec/models/shipping_rate_card_version_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ShippingRateCardVersion, type: :model do
  let(:company) { create(:company) }

  describe "validations" do
    it "requires name, country_code, service_type, effective_from" do
      version = ShippingRateCardVersion.new(company: company)
      expect(version).not_to be_valid
      expect(version.errors.attribute_names).to include(:name, :country_code, :service_type, :effective_from)
    end

    it "rejects effective_to earlier than effective_from" do
      version = build(:shipping_rate_card_version, company: company,
                      effective_from: Date.new(2026, 3, 1), effective_to: Date.new(2026, 2, 1))
      expect(version).not_to be_valid
      expect(version.errors[:effective_to]).to be_present
    end

    it "allows effective_to equal to effective_from" do
      version = build(:shipping_rate_card_version, company: company,
                      effective_from: Date.new(2026, 3, 1), effective_to: Date.new(2026, 3, 1))
      expect(version).to be_valid
    end

    it "allows a nil effective_to" do
      version = build(:shipping_rate_card_version, company: company, effective_to: nil)
      expect(version).to be_valid
    end
  end

  describe ".lookup" do
    let(:args) { { country: "US", service_type: "standard_with_battery" } }

    it "returns the newest applicable version for the date" do
      old = create(:shipping_rate_card_version, company: company,
                   effective_from: Date.new(2026, 1, 1), effective_to: nil, **args)
      new_v = create(:shipping_rate_card_version, company: company,
                     effective_from: Date.new(2026, 4, 1), effective_to: nil, **args)

      expect(described_class.lookup(company: company, on_date: Date.new(2026, 5, 1), **args)).to eq(new_v)
      expect(described_class.lookup(company: company, on_date: Date.new(2026, 2, 1), **args)).to eq(old)
    end

    it "falls back to the most recent past version when none explicitly contains the date" do
      old = create(:shipping_rate_card_version, company: company,
                   effective_from: Date.new(2026, 1, 1), effective_to: nil, **args)
      expect(described_class.lookup(company: company, on_date: Date.new(2026, 12, 31), **args)).to eq(old)
    end

    it "returns nil when no version covers the date" do
      create(:shipping_rate_card_version, company: company,
             effective_from: Date.new(2026, 6, 1), effective_to: nil, **args)
      expect(described_class.lookup(company: company, on_date: Date.new(2026, 1, 1), **args)).to be_nil
    end

    it "excludes a version whose effective_to has passed" do
      create(:shipping_rate_card_version, company: company,
             effective_from: Date.new(2026, 1, 1), effective_to: Date.new(2026, 3, 31), **args)
      expect(described_class.lookup(company: company, on_date: Date.new(2026, 5, 1), **args)).to be_nil
    end

    it "scopes by company" do
      other = create(:company)
      create(:shipping_rate_card_version, company: other,
             effective_from: Date.new(2026, 1, 1), **args)
      expect(described_class.lookup(company: company, on_date: Date.new(2026, 5, 1), **args)).to be_nil
    end
  end

  describe "associations" do
    it "destroys its rates when destroyed" do
      version = create(:shipping_rate_card_version, company: company)
      create(:shipping_rate_card_rate, version: version)
      expect { version.destroy }.to change(ShippingRateCardRate, :count).by(-1)
    end
  end
end
```

- [ ] **Step 3: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/shipping_rate_card_version_spec.rb`
Expected: FAIL — `uninitialized constant ShippingRateCardVersion`.

- [ ] **Step 4: Write the model**

`app/models/shipping_rate_card_version.rb`:

```ruby
class ShippingRateCardVersion < ApplicationRecord
  belongs_to :company
  has_many :rates, class_name: "ShippingRateCardRate", foreign_key: :version_id, dependent: :destroy, inverse_of: :version

  validates :name, :country_code, :service_type, :effective_from, presence: true
  validate  :effective_to_after_from

  scope :for_lookup, ->(country:, service_type:, on_date:) {
    where(country_code: country, service_type: service_type)
      .where("effective_from <= ?", on_date)
      .where("effective_to IS NULL OR effective_to >= ?", on_date)
      .order(effective_from: :desc)
  }

  def self.lookup(company:, country:, service_type:, on_date:)
    where(company_id: company.id)
      .for_lookup(country: country, service_type: service_type, on_date: on_date)
      .first
  end

  private

  def effective_to_after_from
    return unless effective_from && effective_to
    errors.add(:effective_to, "must be on or after effective_from") if effective_to < effective_from
  end
end
```

> NOTE: `spec/factories/shipping_rate_card_rates.rb` (used by the cascade test) is created in Task 3 Step 1. If running this task in isolation, create that factory first or skip the cascade example until Task 3.

- [ ] **Step 5: Run the spec to verify it passes**

Run: `bundle exec rspec spec/models/shipping_rate_card_version_spec.rb`
Expected: PASS (the cascade example needs the rate factory from Task 3).

- [ ] **Step 6: Commit**

```bash
git add app/models/shipping_rate_card_version.rb spec/factories/shipping_rate_card_versions.rb spec/models/shipping_rate_card_version_spec.rb
git commit -m "feat: add ShippingRateCardVersion model with versioned lookup"
```

---

## Task 3: `ShippingRateCardRate` model

**Files:**
- Create: `app/models/shipping_rate_card_rate.rb`
- Create: `spec/factories/shipping_rate_card_rates.rb`
- Test: `spec/models/shipping_rate_card_rate_spec.rb`

- [ ] **Step 1: Write the factory**

`spec/factories/shipping_rate_card_rates.rb`:

```ruby
FactoryBot.define do
  factory :shipping_rate_card_rate do
    association :version, factory: :shipping_rate_card_version
    weight_min_kg { 0.05 }
    weight_max_kg { 0.2 }
    per_kg_rate_cny { 92.0 }
    flat_fee_cny { 25.0 }
  end
end
```

- [ ] **Step 2: Write the failing model spec**

`spec/models/shipping_rate_card_rate_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ShippingRateCardRate, type: :model do
  describe "validations" do
    it "requires the numeric fields" do
      rate = ShippingRateCardRate.new
      expect(rate).not_to be_valid
      expect(rate.errors.attribute_names).to include(:weight_min_kg, :weight_max_kg, :per_kg_rate_cny, :flat_fee_cny)
    end

    it "rejects negative per_kg_rate_cny" do
      rate = build(:shipping_rate_card_rate, per_kg_rate_cny: -1)
      expect(rate).not_to be_valid
    end

    it "requires weight_max_kg greater than weight_min_kg" do
      rate = build(:shipping_rate_card_rate, weight_min_kg: 0.5, weight_max_kg: 0.5)
      expect(rate).not_to be_valid
      expect(rate.errors[:weight_max_kg]).to be_present
    end

    it "is valid with a proper band" do
      expect(build(:shipping_rate_card_rate, weight_min_kg: 0.05, weight_max_kg: 0.2)).to be_valid
    end
  end

  describe ".for_weight" do
    let(:version) { create(:shipping_rate_card_version) }
    let!(:band_a) { create(:shipping_rate_card_rate, version: version, weight_min_kg: 0.05, weight_max_kg: 0.2) }
    let!(:band_b) { create(:shipping_rate_card_rate, version: version, weight_min_kg: 0.201, weight_max_kg: 0.45) }

    it "matches the band whose min < W <= max" do
      expect(version.rates.for_weight(0.2)).to contain_exactly(band_a)
      expect(version.rates.for_weight(0.3)).to contain_exactly(band_b)
    end

    it "matches nothing below the lowest band's min" do
      expect(version.rates.for_weight(0.05)).to be_empty
    end
  end

  describe "associations" do
    it "reaches company through version" do
      company = create(:company)
      version = create(:shipping_rate_card_version, company: company)
      rate = create(:shipping_rate_card_rate, version: version)
      expect(rate.company).to eq(company)
    end
  end
end
```

- [ ] **Step 3: Run the spec to verify it fails**

Run: `bundle exec rspec spec/models/shipping_rate_card_rate_spec.rb`
Expected: FAIL — `uninitialized constant ShippingRateCardRate`.

- [ ] **Step 4: Write the model**

`app/models/shipping_rate_card_rate.rb`:

```ruby
class ShippingRateCardRate < ApplicationRecord
  belongs_to :version, class_name: "ShippingRateCardVersion", foreign_key: :version_id, inverse_of: :rates
  has_one :company, through: :version

  validates :weight_min_kg,   presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :weight_max_kg,   presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :per_kg_rate_cny, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :flat_fee_cny,    presence: true, numericality: { greater_than_or_equal_to: 0 }
  validate  :weight_max_greater_than_min

  scope :for_weight, ->(kg) {
    where("weight_min_kg < ? AND weight_max_kg >= ?", kg, kg)
  }

  private

  def weight_max_greater_than_min
    return unless weight_min_kg && weight_max_kg
    errors.add(:weight_max_kg, "must be greater than weight_min_kg") if weight_max_kg <= weight_min_kg
  end
end
```

- [ ] **Step 5: Run both model specs to verify they pass**

Run: `bundle exec rspec spec/models/shipping_rate_card_rate_spec.rb spec/models/shipping_rate_card_version_spec.rb`
Expected: PASS (including the Task 2 cascade example, now that the rate factory exists).

- [ ] **Step 6: Commit**

```bash
git add app/models/shipping_rate_card_rate.rb spec/factories/shipping_rate_card_rates.rb spec/models/shipping_rate_card_rate_spec.rb
git commit -m "feat: add ShippingRateCardRate model with weight-band lookup"
```

---

## Task 4: Company + Order model extensions

**Files:**
- Modify: `app/models/company.rb`
- Modify: `app/models/order.rb`
- Test: `spec/models/order_spec.rb` (extend), `spec/models/company_spec.rb` (extend or create)

- [ ] **Step 1: Write the failing Order spec additions**

Append to `spec/models/order_spec.rb` (inside the top-level `RSpec.describe Order` block):

```ruby
  describe "shipping cost helpers" do
    it "prefers actual over estimated for effective_shipping_cost" do
      order = build(:order, estimated_shipping_cost: 5, actual_shipping_cost: 8)
      expect(order.effective_shipping_cost).to eq(8)
    end

    it "falls back to estimated when actual is nil" do
      order = build(:order, estimated_shipping_cost: 5, actual_shipping_cost: nil)
      expect(order.effective_shipping_cost).to eq(5)
    end

    it "returns nil for effective_shipping_cost when both are nil" do
      order = build(:order, estimated_shipping_cost: nil, actual_shipping_cost: nil)
      expect(order.effective_shipping_cost).to be_nil
    end

    it "computes net_profit_per_order = total_price - cogs - effective_shipping" do
      order = create(:order, total_price: 100, estimated_shipping_cost: 10)
      create(:order_line_item, order: order, quantity: 2, unit_cost_snapshot: 15)
      expect(order.net_profit_per_order).to eq(100 - 30 - 10)
    end

    it "treats missing shipping as zero in net_profit_per_order" do
      order = create(:order, total_price: 100, estimated_shipping_cost: nil, actual_shipping_cost: nil)
      expect(order.net_profit_per_order).to eq(100 - order.cogs_total)
    end

    it "reports shipping_complete? and shipping_is_actual?" do
      expect(build(:order, estimated_shipping_cost: 3, actual_shipping_cost: nil)).to be_shipping_complete
      expect(build(:order, estimated_shipping_cost: 3, actual_shipping_cost: nil)).not_to be_shipping_is_actual
      expect(build(:order, actual_shipping_cost: 4)).to be_shipping_is_actual
      expect(build(:order, estimated_shipping_cost: nil, actual_shipping_cost: nil)).not_to be_shipping_complete
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/models/order_spec.rb -e "shipping cost helpers"`
Expected: FAIL — `undefined method 'effective_shipping_cost'`.

- [ ] **Step 3: Add methods to the Order model**

Add inside `app/models/order.rb` (after `cogs_complete?`, before the final `end`):

```ruby
  def effective_shipping_cost
    actual_shipping_cost || estimated_shipping_cost
  end

  def net_profit_per_order
    return nil unless total_price
    total_price - cogs_total - (effective_shipping_cost || 0)
  end

  def shipping_complete?
    effective_shipping_cost.present?
  end

  def shipping_is_actual?
    actual_shipping_cost.present?
  end
```

- [ ] **Step 4: Add the Company association**

Add to `app/models/company.rb` (with the other `has_many` lines):

```ruby
  has_many :shipping_rate_card_versions, dependent: :destroy
```

> NOTE: The spec text named this `shipping_rate_cards`, but the table and the controllers both use `shipping_rate_card_versions` — use that exact name (the `ShippingRateCardVersionsController#index` calls `current_company.shipping_rate_card_versions`).

- [ ] **Step 5: Write a Company association spec**

Add to `spec/models/company_spec.rb` (create the file with this shell if it does not exist):

```ruby
require "rails_helper"

RSpec.describe Company, type: :model do
  it "destroys its shipping rate card versions when destroyed" do
    company = create(:company)
    create(:shipping_rate_card_version, company: company)
    expect { company.destroy }.to change(ShippingRateCardVersion, :count).by(-1)
  end
end
```

- [ ] **Step 6: Run both model specs to verify they pass**

Run: `bundle exec rspec spec/models/order_spec.rb spec/models/company_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/models/order.rb app/models/company.rb spec/models/order_spec.rb spec/models/company_spec.rb
git commit -m "feat: add shipping cost helpers to Order and rate-card assoc to Company"
```

---

## Task 5: `ShippingCostCalculator` service

**Files:**
- Create: `app/services/shipping_cost_calculator.rb`
- Test: `spec/services/shipping_cost_calculator_spec.rb`

- [ ] **Step 1: Write the failing service spec**

`spec/services/shipping_cost_calculator_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ShippingCostCalculator do
  let(:company) { create(:company) }
  let(:user) { create(:user) }
  let(:store) do
    create(:shopify_store, user: user, company: company,
           currency: "USD", cost_fx_rate: 7.0, default_service_type: "standard_with_battery")
  end
  let(:customer) { create(:customer, shopify_store: store) }

  # 0.3 kg US order with one weighted variant.
  def build_order(weight_grams: 300, country: "US", ordered_on: Date.new(2026, 4, 15))
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: store.active_timezone.local(ordered_on.year, ordered_on.month, ordered_on.day, 12),
                   shopify_data: { "shipping_address" => { "country_code" => country } })
    product = create(:product, shopify_store: store)
    variant = create(:product_variant, product: product, weight_grams: weight_grams)
    create(:order_line_item, order: order, product_variant: variant, quantity: 1)
    order
  end

  def build_version_with_band(country: "US", service: "standard_with_battery",
                              from: Date.new(2026, 1, 1), to: nil,
                              min: 0.201, max: 0.45, per_kg: 92.0, flat: 23.0, name: "V")
    version = create(:shipping_rate_card_version, company: company, name: name,
                     country_code: country, service_type: service, effective_from: from, effective_to: to)
    create(:shipping_rate_card_rate, version: version,
           weight_min_kg: min, weight_max_kg: max, per_kg_rate_cny: per_kg, flat_fee_cny: flat)
    version
  end

  it "returns the band cost converted to store currency" do
    build_version_with_band
    order = build_order(weight_grams: 300) # 0.3 kg → band 0.201..0.45
    # cny = 0.3 * 92 + 23 = 50.6; usd = 50.6 / 7.0 = 7.23
    expect(ShippingCostCalculator.estimate(order)).to eq(7.23)
  end

  it "uses the older version for an early date and the newer one once it takes over" do
    build_version_with_band(name: "old", from: Date.new(2026, 1, 1), per_kg: 92.0, flat: 23.0)
    build_version_with_band(name: "new", from: Date.new(2026, 5, 1), per_kg: 100.0, flat: 30.0)

    early = build_order(weight_grams: 300, ordered_on: Date.new(2026, 4, 15))
    late  = build_order(weight_grams: 300, ordered_on: Date.new(2026, 5, 10))

    expect(ShippingCostCalculator.estimate(early)).to eq(((0.3 * 92.0) + 23.0) / 7.0).round(2)
    expect(ShippingCostCalculator.estimate(late)).to eq((((0.3 * 100.0) + 30.0) / 7.0).round(2))
  end

  it "returns nil when the variant has no weight" do
    build_version_with_band
    order = build_order(weight_grams: nil)
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when ANY line item lacks a weight (avoids underestimating)" do
    build_version_with_band
    order = build_order(weight_grams: 300) # first line has weight
    weightless_variant = create(:product_variant, product: create(:product, shopify_store: store), weight_grams: nil)
    create(:order_line_item, order: order, product_variant: weightless_variant, quantity: 1)
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when the order has no ordered_at" do
    build_version_with_band
    order = build_order(weight_grams: 300)
    order.update_column(:ordered_at, nil)
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "falls back to billing_address country when shipping_address is missing" do
    build_version_with_band(country: "US")
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                   shopify_data: { "billing_address" => { "country_code" => "US" } })
    product = create(:product, shopify_store: store)
    variant = create(:product_variant, product: product, weight_grams: 300)
    create(:order_line_item, order: order, product_variant: variant, quantity: 1)
    expect(ShippingCostCalculator.estimate(order)).to eq(7.23)
  end

  it "returns nil when no country can be determined" do
    build_version_with_band
    order = create(:order, customer: customer, shopify_store: store, shopify_data: {})
    product = create(:product, shopify_store: store)
    variant = create(:product_variant, product: product, weight_grams: 300)
    create(:order_line_item, order: order, product_variant: variant, quantity: 1)
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when no version covers the date" do
    build_version_with_band(from: Date.new(2026, 6, 1))
    order = build_order(ordered_on: Date.new(2026, 1, 1))
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when no weight band matches" do
    build_version_with_band(min: 1.0, max: 2.0)
    order = build_order(weight_grams: 300)
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when the store has no default_service_type" do
    build_version_with_band
    store.update!(default_service_type: nil)
    order = build_order
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when the store has no cost_fx_rate" do
    build_version_with_band
    store.update!(cost_fx_rate: nil)
    order = build_order
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/shipping_cost_calculator_spec.rb`
Expected: FAIL — `uninitialized constant ShippingCostCalculator`.

- [ ] **Step 3: Write the service**

`app/services/shipping_cost_calculator.rb`:

```ruby
class ShippingCostCalculator
  def self.estimate(order)
    new(order).call
  end

  def initialize(order)
    @order = order
    @store = order.shopify_store
  end

  def call
    return nil unless @store&.cost_fx_rate&.positive?
    return nil unless @store.default_service_type.present?
    return nil unless @order.ordered_at

    country = country_code_from_order
    return nil unless country

    weight_kg = total_weight_kg
    return nil unless weight_kg && weight_kg.positive?

    version = ShippingRateCardVersion.lookup(
      company:      @store.company,
      country:      country,
      service_type: @store.default_service_type,
      on_date:      @order.ordered_at.to_date
    )
    return nil unless version

    rate = version.rates.for_weight(weight_kg).first
    return nil unless rate

    cost_cny = (weight_kg * rate.per_kg_rate_cny) + rate.flat_fee_cny
    (cost_cny / @store.cost_fx_rate).round(2)
  end

  private

  def country_code_from_order
    @order.shopify_data&.dig("shipping_address", "country_code") ||
      @order.shopify_data&.dig("billing_address", "country_code")
  end

  def total_weight_kg
    items = @order.order_line_items.includes(:product_variant).to_a
    return nil if items.empty?
    # If any line lacks a usable weight, refuse to estimate rather than
    # silently treating it as 0 (which would underestimate the cost).
    return nil if items.any? { |li| li.product_variant&.weight_grams.blank? }
    items.sum { |li| li.product_variant.weight_grams * li.quantity } / 1000.0
  end
end
```

> NOTE (from Codex review): this is intentionally STRICTER than the spec's sample (`(weight_grams || 0)`). Returning `nil` when any line is weightless prevents a partial-weight order from producing a too-low estimate, and matches the spec's stated intent ("returns nil if any input is missing"). The `ordered_at` guard above prevents a `NoMethodError` on the nullable `orders.ordered_at` column.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/shipping_cost_calculator_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/shipping_cost_calculator.rb spec/services/shipping_cost_calculator_spec.rb
git commit -m "feat: add ShippingCostCalculator service"
```

---

## Task 6: Snapshot estimated shipping cost during order sync

**Files:**
- Modify: `app/services/sync_all_orders_service.rb` (around line 110, after `sync_fulfillments`, and add a private helper)
- Test: `spec/services/sync_all_orders_service_spec.rb` (extend)

- [ ] **Step 1: Write the failing spec additions**

Add a new `describe` block to `spec/services/sync_all_orders_service_spec.rb`. Adapt the setup to match how the existing spec builds a store + shopify payload (reuse its `let`/helper for the Shopify order hash). The behavioral assertions:

```ruby
  describe "estimated shipping cost snapshot" do
    let(:user) { create(:user) }
    let(:store) do
      create(:shopify_store, user: user, company: user.companies.first,
             currency: "USD", cost_fx_rate: 7.0, default_service_type: "standard_with_battery")
    end

    before do
      version = create(:shipping_rate_card_version, company: store.company,
                       country_code: "US", service_type: "standard_with_battery",
                       effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: version,
             weight_min_kg: 0.201, weight_max_kg: 0.45, per_kg_rate_cny: 92.0, flat_fee_cny: 23.0)
    end

    # Build a Shopify order payload with one 0.3 kg line, a US shipping address,
    # and an ordered_at inside the active version's window. Reuse the existing
    # spec's payload helper; ensure the matching ProductVariant (weight_grams: 300)
    # exists for the line item's variant_id so the calculator can read its weight.

    it "sets orders.estimated_shipping_cost from the calculator" do
      # ... run the service over the payload ...
      order = store.orders.find_by(shopify_order_id: <payload id>)
      expect(order.estimated_shipping_cost).to eq(7.23)
    end

    it "does not overwrite an existing estimated_shipping_cost on re-sync" do
      # first sync sets it; manually change it; re-sync; expect unchanged
      order = store.orders.find_by(shopify_order_id: <payload id>)
      order.update!(estimated_shipping_cost: 99.99)
      # ... run the service again over the same payload ...
      expect(order.reload.estimated_shipping_cost).to eq(99.99)
    end

    it "never sets actual_shipping_cost" do
      # ... run the service ...
      order = store.orders.find_by(shopify_order_id: <payload id>)
      expect(order.actual_shipping_cost).to be_nil
    end
  end
```

> The `<payload id>` and the payload-construction lines must match the existing spec's conventions in this file — read the top of `spec/services/sync_all_orders_service_spec.rb` first and mirror its helper (the one that produces the `shopify_order` hash and the variants). Keep `shipping_address.country_code = "US"`, one line item of `grams`-equivalent weight 300 (set `ProductVariant#weight_grams = 300`), and `ordered_at` in April 2026.

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/sync_all_orders_service_spec.rb -e "estimated shipping cost snapshot"`
Expected: FAIL — `estimated_shipping_cost` is nil (no snapshot call yet).

- [ ] **Step 3: Insert the snapshot call and helper**

In `app/services/sync_all_orders_service.rb`, in `sync_order`, insert the call BETWEEN `sync_line_items` (line 109) and `sync_fulfillments` (line 110):

```ruby
    sync_line_items(order, shopify_order)
    sync_estimated_shipping_cost(order)
    sync_fulfillments(order, shopify_order)
```

> ORDER MATTERS (from Codex review + spec): the snapshot must run AFTER `sync_line_items` (so the persisted line items + variant weights exist) but BEFORE `sync_fulfillments` (which makes a live Shopify API call via `@shopify.fetch_fulfillments` — a fulfillment fetch failure must not prevent the shipping snapshot from being recorded). This matches the spec's `SyncAllOrdersService modification` section exactly.

Add the private helper (alongside the other private `sync_*` methods):

```ruby
  def sync_estimated_shipping_cost(order)
    return if order.estimated_shipping_cost.present? # frozen once set
    cost = ShippingCostCalculator.estimate(order)
    order.update!(estimated_shipping_cost: cost) if cost
  end
```

> Place the call AFTER `sync_line_items` so the line items (and their variant weights) exist when the calculator reads them.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/sync_all_orders_service_spec.rb`
Expected: PASS (the whole file, to confirm no regression).

- [ ] **Step 5: Commit**

```bash
git add app/services/sync_all_orders_service.rb spec/services/sync_all_orders_service_spec.rb
git commit -m "feat: snapshot estimated shipping cost during order sync"
```

---

## Task 7: Backfill historical estimated shipping cost

**Files:**
- Modify: `app/services/backfill_order_line_items_service.rb`
- Test: `spec/services/backfill_order_line_items_service_spec.rb` (extend)

- [ ] **Step 1: Write the failing spec additions**

Add to `spec/services/backfill_order_line_items_service_spec.rb`:

```ruby
  describe "estimated shipping backfill" do
    let(:user) { create(:user) }
    let(:store) do
      create(:shopify_store, user: user, company: user.companies.first,
             currency: "USD", cost_fx_rate: 7.0, default_service_type: "standard_with_battery")
    end
    let(:customer) { create(:customer, shopify_store: store) }

    before do
      version = create(:shipping_rate_card_version, company: store.company,
                       country_code: "US", service_type: "standard_with_battery",
                       effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: version,
             weight_min_kg: 0.201, weight_max_kg: 0.45, per_kg_rate_cny: 92.0, flat_fee_cny: 23.0)
    end

    def order_with_weighted_line(estimated: nil, actual: nil)
      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     estimated_shipping_cost: estimated, actual_shipping_cost: actual,
                     shopify_data: { "shipping_address" => { "country_code" => "US" } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 300)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      order
    end

    it "fills estimated_shipping_cost when null and counts it" do
      order = order_with_weighted_line(estimated: nil)
      result = BackfillOrderLineItemsService.new(store).call
      expect(order.reload.estimated_shipping_cost).to eq(7.23)
      expect(result[:shipping_filled]).to eq(1)
    end

    it "does not overwrite an existing estimated_shipping_cost" do
      order = order_with_weighted_line(estimated: 42.0)
      BackfillOrderLineItemsService.new(store).call
      expect(order.reload.estimated_shipping_cost).to eq(42.0)
    end

    it "never touches actual_shipping_cost" do
      order = order_with_weighted_line(estimated: nil)
      BackfillOrderLineItemsService.new(store).call
      expect(order.reload.actual_shipping_cost).to be_nil
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/backfill_order_line_items_service_spec.rb -e "estimated shipping backfill"`
Expected: FAIL — `result[:shipping_filled]` is nil / estimate not set.

- [ ] **Step 3: Extend the service**

Edit `app/services/backfill_order_line_items_service.rb`. In `initialize`, add the counter:

```ruby
  def initialize(shopify_store)
    @store = shopify_store
    @processed = 0
    @snapshotted = 0
    @shipping_filled = 0
  end
```

Replace the `call` method body to call the new helper per order and return the extended hash:

```ruby
  def call
    Rails.logger.info("[BackfillLineItems] start store=#{@store.shop_domain}")
    @store.orders.find_each(batch_size: 200) do |order|
      (order.shopify_data&.dig("line_items") || []).each { |li| upsert_line_item(order, li) }
      backfill_estimated_shipping(order)
      @processed += 1
    end
    Rails.logger.info("[BackfillLineItems] done orders=#{@processed} snapshotted=#{@snapshotted} shipping=#{@shipping_filled}")
    { orders: @processed, snapshotted: @snapshotted, shipping_filled: @shipping_filled }
  end
```

Add the private helper:

```ruby
  def backfill_estimated_shipping(order)
    return if order.estimated_shipping_cost.present?
    cost = ShippingCostCalculator.estimate(order)
    return unless cost
    order.update!(estimated_shipping_cost: cost)
    @shipping_filled += 1
  end
```

> `backfill_estimated_shipping` runs AFTER the line-item upsert loop so the variant weights are present. The calculator reads `order.order_line_items` (DB-backed), so it picks up the just-upserted items.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/backfill_order_line_items_service_spec.rb`
Expected: PASS (whole file).

- [ ] **Step 5: Commit**

```bash
git add app/services/backfill_order_line_items_service.rb spec/services/backfill_order_line_items_service_spec.rb
git commit -m "feat: backfill historical estimated shipping cost"
```

---

## Task 8: Routes, page authorization, and i18n keys

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/admin_controller.rb`
- Modify: `config/locales/en.yml`, `config/locales/zh-CN.yml`, `config/locales/zh-TW.yml`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the `scope "(:locale)" do ... authenticated block`, after the `resources :product_variants` block (around line 71), add:

```ruby
    resources :shipping_rate_card_versions, only: [ :index, :create, :update, :destroy ] do
      resources :rates, only: [ :create, :update, :destroy ],
                controller: "shipping_rate_card_rates"
    end
```

- [ ] **Step 2: Add the permission map entries**

In `app/controllers/admin_controller.rb`, add two entries to `PERMISSION_KEY_MAP` (before the closing `}.freeze`):

```ruby
    "shipping_rate_card_versions" => "shopify_stores",
    "shipping_rate_card_rates"    => "shopify_stores"
```

- [ ] **Step 3: Add the en locale keys**

In `config/locales/en.yml`, add a top-level `shipping_rate_cards:` block (sibling of `shopify_stores:`), extend `shopify_stores:`, and extend `dashboard:`:

```yaml
  shipping_rate_cards:
    title: "Shipping Rate Cards"
    filter_country: "Country"
    filter_service: "Service"
    filter_all: "All"
    new_version_title: "New version"
    create_version: "Create version"
    add_band: "Add band"
    version_created: "Version created"
    version_updated: "Version updated"
    version_deleted: "Version deleted"
    rate_created: "Rate band added"
    rate_updated: "Rate band updated"
    rate_deleted: "Rate band deleted"
    empty: "No rate card versions yet — create one above"
    until_superseded: "until superseded"
    columns:
      name: "Name"
      country: "Country"
      service: "Service"
      weight_min: "Min kg"
      weight_max: "Max kg"
      per_kg: "¥/kg"
      flat_fee: "¥/pkg"
      effective_from: "From"
      effective_to: "Until"
```

Under the existing `shopify_stores:` block add:

```yaml
    default_service_type: "Default shipping service type"
    default_service_hint: "Used when estimating shipping cost for orders from this store"
    service_type_updated: "Default service type updated"
    service_type_owner_only: "(Only owners can change this)"
    save_service_type: "Save"
```

Under the existing `dashboard:` block add:

```yaml
    shipping_cost: "Shipping cost"
    shipping_coverage: "Shipping coverage"
    shipping_coverage_actual: "actual"
    shipping_coverage_estimated: "estimated"
```

Under the existing `nav:` block add (for the sidebar link in Step 4b):

```yaml
    shipping_rate_cards: "Shipping Rate Cards"
```

- [ ] **Step 4: Mirror the keys into zh-CN.yml and zh-TW.yml**

Add the same key structure under the matching locale roots. Translations:

zh-CN (`config/locales/zh-CN.yml`):
```yaml
  shipping_rate_cards:
    title: "运费费率卡"
    filter_country: "国家"
    filter_service: "服务类型"
    filter_all: "全部"
    new_version_title: "新建版本"
    create_version: "创建版本"
    add_band: "添加重量段"
    version_created: "版本已创建"
    version_updated: "版本已更新"
    version_deleted: "版本已删除"
    rate_created: "已添加费率段"
    rate_updated: "费率段已更新"
    rate_deleted: "费率段已删除"
    empty: "暂无费率卡版本 — 请在上方创建"
    until_superseded: "直到被取代"
    columns:
      name: "名称"
      country: "国家"
      service: "服务类型"
      weight_min: "最小 kg"
      weight_max: "最大 kg"
      per_kg: "¥/kg"
      flat_fee: "¥/件"
      effective_from: "生效日"
      effective_to: "截止日"
```
zh-CN `shopify_stores:` additions:
```yaml
    default_service_type: "默认运输服务类型"
    default_service_hint: "用于估算该店铺订单的运费"
    service_type_updated: "默认服务类型已更新"
    service_type_owner_only: "（仅所有者可修改）"
    save_service_type: "保存"
```
zh-CN `dashboard:` additions:
```yaml
    shipping_cost: "运费成本"
    shipping_coverage: "运费覆盖率"
    shipping_coverage_actual: "实际"
    shipping_coverage_estimated: "估算"
```
zh-CN `nav:` addition:
```yaml
    shipping_rate_cards: "运费费率卡"
```

zh-TW (`config/locales/zh-TW.yml`):
```yaml
  shipping_rate_cards:
    title: "運費費率卡"
    filter_country: "國家"
    filter_service: "服務類型"
    filter_all: "全部"
    new_version_title: "新增版本"
    create_version: "建立版本"
    add_band: "新增重量段"
    version_created: "版本已建立"
    version_updated: "版本已更新"
    version_deleted: "版本已刪除"
    rate_created: "已新增費率段"
    rate_updated: "費率段已更新"
    rate_deleted: "費率段已刪除"
    empty: "尚無費率卡版本 — 請在上方建立"
    until_superseded: "直到被取代"
    columns:
      name: "名稱"
      country: "國家"
      service: "服務類型"
      weight_min: "最小 kg"
      weight_max: "最大 kg"
      per_kg: "¥/kg"
      flat_fee: "¥/件"
      effective_from: "生效日"
      effective_to: "截止日"
```
zh-TW `shopify_stores:` additions:
```yaml
    default_service_type: "預設運送服務類型"
    default_service_hint: "用於估算此商店訂單的運費"
    service_type_updated: "預設服務類型已更新"
    service_type_owner_only: "（僅擁有者可修改）"
    save_service_type: "儲存"
```
zh-TW `dashboard:` additions:
```yaml
    shipping_cost: "運費成本"
    shipping_coverage: "運費覆蓋率"
    shipping_coverage_actual: "實際"
    shipping_coverage_estimated: "估算"
```
zh-TW `nav:` addition:
```yaml
    shipping_rate_cards: "運費費率卡"
```

- [ ] **Step 4b: Add the sidebar nav link**

In `app/views/shared/_sidebar.html.erb`, immediately after the `shopify_stores` link block (the `<% if current_membership&.has_permission?("shopify_stores") %> … <% end %>` ending around line 141), add a link gated by the SAME permission (the page authorizes via `PERMISSION_KEY_MAP["shipping_rate_card_versions"] => "shopify_stores"`):

```erb
          <% if current_membership&.has_permission?("shopify_stores") %>
            <%= link_to shipping_rate_card_versions_path, data: { action: "click->sidebar#close" },
                class: "flex items-center gap-3 px-3 py-2 text-sm font-medium rounded-md #{current_page?(shipping_rate_card_versions_path) ? 'bg-gray-100 text-gray-900' : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900'}" do %>
              <svg class="w-4 h-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" d="M3.75 9.75h16.5m-16.5 0v7.5a2.25 2.25 0 0 0 2.25 2.25h12a2.25 2.25 0 0 0 2.25-2.25v-7.5m-16.5 0L5.25 5.25A2.25 2.25 0 0 1 7.5 3.75h9a2.25 2.25 0 0 1 2.25 1.5l1.5 4.5" />
              </svg>
              <%= t("nav.shipping_rate_cards") %>
            <% end %>
          <% end %>
```

- [ ] **Step 5: Verify routes load and locales parse**

Run: `bin/rails runner "puts Rails.application.routes.url_helpers.shipping_rate_card_versions_path"`
Expected: prints `/shipping_rate_card_versions` (no error).

Run: `bin/rails runner "%w[en zh-CN zh-TW].each { |l| I18n.with_locale(l) { I18n.t('shipping_rate_cards.title'); I18n.t('nav.shipping_rate_cards') } }; puts 'ok'"`
Expected: prints `ok` with no `translation missing`.

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/admin_controller.rb \
        config/locales/en.yml config/locales/zh-CN.yml config/locales/zh-TW.yml \
        app/views/shared/_sidebar.html.erb
git commit -m "feat: add shipping rate card routes, authz mapping, i18n keys, nav link"
```

---

## Task 9: `ShippingRateCardVersionsController`

**Files:**
- Create: `app/controllers/shipping_rate_card_versions_controller.rb`
- Test: `spec/requests/shipping_rate_card_versions_spec.rb`

> Views referenced by `index`/`update` are created in Task 13. To make the request spec green here, this task creates a MINIMAL `index.html.erb` and `update.turbo_stream.erb` placeholder; Task 13 replaces them with the full UI. (Without a template, `index` would raise `ActionView::MissingTemplate`.)

- [ ] **Step 1: Write the failing request spec**

`spec/requests/shipping_rate_card_versions_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "ShippingRateCardVersions", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let(:member_user) { create(:user) }
  let!(:member_membership) do
    create(:membership, company: company, user: member_user, role: :member, permissions: %w[shopify_stores])
  end

  let(:valid_attrs) do
    { name: "Q2 2026 US Battery", country_code: "US", service_type: "standard_with_battery",
      effective_from: "2026-04-01", effective_to: "" }
  end

  describe "GET /shipping_rate_card_versions" do
    before { sign_in owner }

    it "returns 200 and lists versions with rates" do
      version = create(:shipping_rate_card_version, company: company, name: "Q1 US")
      create(:shipping_rate_card_rate, version: version)
      get shipping_rate_card_versions_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Q1 US")
    end

    it "filters by country_code" do
      create(:shipping_rate_card_version, company: company, name: "US one", country_code: "US")
      create(:shipping_rate_card_version, company: company, name: "CA one", country_code: "CA")
      get shipping_rate_card_versions_path(country_code: "CA")
      expect(response.body).to include("CA one")
      expect(response.body).not_to include("US one")
    end
  end

  describe "POST /shipping_rate_card_versions" do
    it "creates a version for an owner" do
      sign_in owner
      expect {
        post shipping_rate_card_versions_path, params: { shipping_rate_card_version: valid_attrs }
      }.to change(ShippingRateCardVersion, :count).by(1)
      expect(response).to redirect_to(shipping_rate_card_versions_path)
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      expect {
        post shipping_rate_card_versions_path, params: { shipping_rate_card_version: valid_attrs }
      }.not_to change(ShippingRateCardVersion, :count)
      expect(response).to redirect_to(shipping_rate_card_versions_path)
    end
  end

  describe "PATCH /shipping_rate_card_versions/:id" do
    let!(:version) { create(:shipping_rate_card_version, company: company, name: "Old name") }

    it "updates a field and renders a Turbo Stream for an owner" do
      sign_in owner
      patch shipping_rate_card_version_path(version),
            params: { shipping_rate_card_version: { name: "New name" } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response.media_type).to include("turbo-stream")
      expect(version.reload.name).to eq("New name")
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      patch shipping_rate_card_version_path(version),
            params: { shipping_rate_card_version: { name: "Hacked" } }
      expect(version.reload.name).to eq("Old name")
    end
  end

  describe "DELETE /shipping_rate_card_versions/:id" do
    let!(:version) { create(:shipping_rate_card_version, company: company) }

    it "destroys for an owner and cascades to rates" do
      create(:shipping_rate_card_rate, version: version)
      sign_in owner
      expect {
        delete shipping_rate_card_version_path(version)
      }.to change(ShippingRateCardVersion, :count).by(-1).and change(ShippingRateCardRate, :count).by(-1)
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      expect {
        delete shipping_rate_card_version_path(version)
      }.not_to change(ShippingRateCardVersion, :count)
    end
  end

  describe "cross-company isolation" do
    it "404s on another company's version" do
      other_version = create(:shipping_rate_card_version) # different company
      sign_in owner
      patch shipping_rate_card_version_path(other_version),
            params: { shipping_rate_card_version: { name: "x" } }
      expect(response).to have_http_status(:not_found)
    end
  end
end
```

> NOTE on the 404 expectation: a scoped `current_company.shipping_rate_card_versions.find(...)` raises `ActiveRecord::RecordNotFound`, which Rails renders as 404 in the test env. If this app rescues it differently, adjust the assertion to match the app's convention (check how `product_variants_spec.rb` handles cross-company — it rescues `RecordNotFound`).

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/requests/shipping_rate_card_versions_spec.rb`
Expected: FAIL — uninitialized constant / routing or missing controller.

- [ ] **Step 3: Write the controller**

`app/controllers/shipping_rate_card_versions_controller.rb`:

```ruby
class ShippingRateCardVersionsController < AdminController
  before_action :require_owner!, only: [ :create, :update, :destroy ]
  before_action :set_version, only: [ :update, :destroy ]

  def index
    versions = current_company.shipping_rate_card_versions.includes(:rates)
    @countries = versions.distinct.pluck(:country_code).sort
    @services  = versions.distinct.pluck(:service_type).sort

    versions = versions.where(country_code: params[:country_code]) if params[:country_code].present?
    versions = versions.where(service_type: params[:service_type]) if params[:service_type].present?

    @selected_country = params[:country_code]
    @selected_service = params[:service_type]
    @versions = versions.order(country_code: :asc, service_type: :asc, effective_from: :desc)
  end

  def create
    version = current_company.shipping_rate_card_versions.new(version_params)
    if version.save
      redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.version_created")
    else
      redirect_to shipping_rate_card_versions_path, alert: version.errors.full_messages.join(", ")
    end
  end

  def update
    if @version.update(version_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.version_updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_to shipping_rate_card_versions_path, alert: @version.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @version.destroy
    redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.version_deleted")
  end

  private

  def set_version
    @version = current_company.shipping_rate_card_versions.find(params[:id])
  end

  def version_params
    params.require(:shipping_rate_card_version).permit(
      :name, :country_code, :service_type, :effective_from, :effective_to
    )
  end

  def require_owner!
    redirect_to(shipping_rate_card_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
```

- [ ] **Step 4: Create placeholder views (replaced fully in Task 13)**

`app/views/shipping_rate_card_versions/index.html.erb`:

```erb
<h1><%= t("shipping_rate_cards.title") %></h1>
<div id="versions">
  <% @versions.each do |version| %>
    <div id="<%= dom_id(version) %>"><%= version.name %></div>
  <% end %>
</div>
```

`app/views/shipping_rate_card_versions/update.turbo_stream.erb`:

```erb
<%= turbo_stream.replace dom_id(@version) do %>
  <div id="<%= dom_id(@version) %>"><%= @version.name %></div>
<% end %>
```

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec rspec spec/requests/shipping_rate_card_versions_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/shipping_rate_card_versions_controller.rb \
        app/views/shipping_rate_card_versions/index.html.erb \
        app/views/shipping_rate_card_versions/update.turbo_stream.erb \
        spec/requests/shipping_rate_card_versions_spec.rb
git commit -m "feat: add ShippingRateCardVersionsController (owner-gated CRUD)"
```

---

## Task 10: `ShippingRateCardRatesController`

**Files:**
- Create: `app/controllers/shipping_rate_card_rates_controller.rb`
- Test: `spec/requests/shipping_rate_card_rates_spec.rb`

> Like Task 9, create a minimal `update.turbo_stream.erb` placeholder so the PATCH spec can render; Task 13 replaces it.

- [ ] **Step 1: Write the failing request spec**

`spec/requests/shipping_rate_card_rates_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "ShippingRateCardRates", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let(:member_user) { create(:user) }
  let!(:member_membership) do
    create(:membership, company: company, user: member_user, role: :member, permissions: %w[shopify_stores])
  end
  let!(:version) { create(:shipping_rate_card_version, company: company) }

  let(:valid_attrs) { { weight_min_kg: "0.05", weight_max_kg: "0.2", per_kg_rate_cny: "92.0", flat_fee_cny: "25.0" } }

  describe "POST .../rates" do
    it "creates a rate for an owner" do
      sign_in owner
      expect {
        post shipping_rate_card_version_rates_path(version), params: { shipping_rate_card_rate: valid_attrs }
      }.to change(version.rates, :count).by(1)
      expect(response).to redirect_to(shipping_rate_card_versions_path)
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      expect {
        post shipping_rate_card_version_rates_path(version), params: { shipping_rate_card_rate: valid_attrs }
      }.not_to change(ShippingRateCardRate, :count)
    end
  end

  describe "PATCH .../rates/:id" do
    let!(:rate) { create(:shipping_rate_card_rate, version: version, per_kg_rate_cny: 92.0) }

    it "updates and renders Turbo Stream for an owner" do
      sign_in owner
      patch shipping_rate_card_version_rate_path(version, rate),
            params: { shipping_rate_card_rate: { per_kg_rate_cny: "100.0" } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response.media_type).to include("turbo-stream")
      expect(rate.reload.per_kg_rate_cny).to eq(100.0)
    end
  end

  describe "DELETE .../rates/:id" do
    let!(:rate) { create(:shipping_rate_card_rate, version: version) }

    it "destroys for an owner" do
      sign_in owner
      expect {
        delete shipping_rate_card_version_rate_path(version, rate)
      }.to change(ShippingRateCardRate, :count).by(-1)
    end
  end

  describe "cross-company isolation" do
    it "404s when the version belongs to another company" do
      other_version = create(:shipping_rate_card_version)
      other_rate = create(:shipping_rate_card_rate, version: other_version)
      sign_in owner
      patch shipping_rate_card_version_rate_path(other_version, other_rate),
            params: { shipping_rate_card_rate: { per_kg_rate_cny: "1" } }
      expect(response).to have_http_status(:not_found)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/requests/shipping_rate_card_rates_spec.rb`
Expected: FAIL — uninitialized constant / missing controller.

- [ ] **Step 3: Write the controller**

`app/controllers/shipping_rate_card_rates_controller.rb`:

```ruby
class ShippingRateCardRatesController < AdminController
  before_action :require_owner!
  before_action :set_version
  before_action :set_rate, only: [ :update, :destroy ]

  def create
    rate = @version.rates.new(rate_params)
    if rate.save
      redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.rate_created")
    else
      redirect_to shipping_rate_card_versions_path, alert: rate.errors.full_messages.join(", ")
    end
  end

  def update
    if @rate.update(rate_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.rate_updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_to shipping_rate_card_versions_path, alert: @rate.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @rate.destroy
    redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.rate_deleted")
  end

  private

  def set_version
    @version = current_company.shipping_rate_card_versions.find(params[:shipping_rate_card_version_id])
  end

  def set_rate
    @rate = @version.rates.find(params[:id])
  end

  def rate_params
    params.require(:shipping_rate_card_rate).permit(:weight_min_kg, :weight_max_kg, :per_kg_rate_cny, :flat_fee_cny)
  end

  def require_owner!
    redirect_to(shipping_rate_card_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
```

> ORDER MATTERS: `require_owner!` is registered before `set_version`, so a non-owner is redirected before any DB lookup. The cross-company 404 case (owner of company A hitting company B's version) is caught by `set_version`'s scoped `find`.

- [ ] **Step 4: Create placeholder update view (replaced in Task 13)**

`app/views/shipping_rate_card_rates/update.turbo_stream.erb`:

```erb
<%= turbo_stream.replace dom_id(@rate) do %>
  <tr id="<%= dom_id(@rate) %>"><td><%= @rate.per_kg_rate_cny %></td></tr>
<% end %>
```

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec rspec spec/requests/shipping_rate_card_rates_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/shipping_rate_card_rates_controller.rb \
        app/views/shipping_rate_card_rates/update.turbo_stream.erb \
        spec/requests/shipping_rate_card_rates_spec.rb
git commit -m "feat: add nested ShippingRateCardRatesController (owner-gated)"
```

---

## Task 11: `default_service_type` on the store

**Files:**
- Modify: `app/controllers/shopify_stores_controller.rb`
- Test: `spec/requests/shopify_stores_spec.rb` (extend; create if absent)

- [ ] **Step 1: Write the failing request spec additions**

Add to `spec/requests/shopify_stores_spec.rb`:

```ruby
  describe "PATCH /shopify_stores/:id default_service_type" do
    let(:owner) { create(:user) }
    let(:company) { owner.companies.first }
    let(:store) { create(:shopify_store, user: owner, company: company) }
    let(:member_user) { create(:user) }
    let!(:member_membership) do
      create(:membership, company: company, user: member_user, role: :member, permissions: %w[shopify_stores])
    end

    it "updates default_service_type for an owner" do
      sign_in owner
      patch shopify_store_path(store), params: { shopify_store: { default_service_type: "standard_with_battery" } }
      expect(store.reload.default_service_type).to eq("standard_with_battery")
      expect(response).to redirect_to(shopify_store_path(store))
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      patch shopify_store_path(store), params: { shopify_store: { default_service_type: "hacked" } }
      expect(store.reload.default_service_type).to be_nil
    end
  end
```

> If `spec/requests/shopify_stores_spec.rb` does not exist, create it with the standard `require "rails_helper"` header and an `RSpec.describe "ShopifyStores", type: :request do ... end` wrapper around this block.

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/requests/shopify_stores_spec.rb -e "default_service_type"`
Expected: FAIL — `default_service_type` stays nil (no branch handles it; it falls through to the generic update).

- [ ] **Step 3: Add the controller branch + strong params**

In `app/controllers/shopify_stores_controller.rb`, add a new branch in `update` immediately after the `cost_fx_rate` branch (after its `end`, around line 34):

```ruby
    if params[:shopify_store].is_a?(ActionController::Parameters) && params[:shopify_store].key?(:default_service_type)
      return redirect_to(shopify_store_path(@shopify_store), alert: t("companies.no_permission")) unless current_membership&.owner?

      if @shopify_store.update(shopify_store_service_params)
        redirect_to shopify_store_path(@shopify_store), notice: t("shopify_stores.service_type_updated")
      else
        redirect_to shopify_store_path(@shopify_store), alert: @shopify_store.errors.full_messages.join(", ")
      end
      return
    end
```

Add the strong-params method in the `private` section (next to `shopify_store_fx_params`):

```ruby
  def shopify_store_service_params
    params.require(:shopify_store).permit(:default_service_type)
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/requests/shopify_stores_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/shopify_stores_controller.rb spec/requests/shopify_stores_spec.rb
git commit -m "feat: owner-only default_service_type update on ShopifyStore"
```

---

## Task 12: Extend `cell_edit_controller.js` for text/date and configurable param

**Files:**
- Modify: `app/javascript/controllers/cell_edit_controller.js`

> The current controller hardcodes the param wrapper `product_variant[...]` and forces `type="number"`. The rate-card UI needs `shipping_rate_card_version[...]` / `shipping_rate_card_rate[...]` wrappers and `text` / `date` inputs. This task adds two Stimulus values: `param` (default `"product_variant"`, preserving existing call sites) and `type` (default `"number"`). No JS unit-test harness exists in this repo; behavior is verified by the Task 16 system spec.

- [ ] **Step 1: Rewrite the controller**

Replace the full contents of `app/javascript/controllers/cell_edit_controller.js` with:

```javascript
import { Controller } from "@hotwired/stimulus"

// Click-to-edit a single field on a record from inside a table cell.
//
// Markup:
//   <td data-controller="cell-edit"
//       data-cell-edit-url-value="/shipping_rate_card_versions/123/rates/456"
//       data-cell-edit-param-value="shipping_rate_card_rate"
//       data-cell-edit-field-value="per_kg_rate_cny"
//       data-cell-edit-type-value="number"
//       data-cell-edit-step-value="0.01"
//       data-cell-edit-min-value="0">
//     <span data-cell-edit-target="display"
//           data-action="click->cell-edit#startEdit">12.50</span>
//   </td>
//
// type can be "number" (default), "text", or "date".
// param is the strong-params wrapper key (default "product_variant").
// Server must respond with a Turbo Stream that replaces the entire row.

export default class extends Controller {
  static targets = ["display"]
  static values  = {
    url:   String,
    param: { type: String, default: "product_variant" },
    field: String,
    type:  { type: String, default: "number" },
    step:  { type: String, default: "0.01" },
    min:   { type: String, default: "0" },
    blank: { type: String, default: "—" }
  }

  startEdit(event) {
    // Stimulus also fires this on keydown.space; stop the default page scroll.
    if (event && event.type === "keydown" && event.key === " ") event.preventDefault()
    if (this.element.querySelector("input")) return // already editing

    const currentText = this.displayTarget.textContent.trim()
    const isBlank = currentText === this.blankValue
    let currentValue
    if (this.typeValue === "number") {
      // Strip thousands separators, currency / unit suffixes, etc.
      const cleaned = currentText.replace(/[^\d.\-]/g, "")
      currentValue = (isBlank || cleaned === "" || cleaned === "-") ? "" : cleaned
    } else {
      currentValue = isBlank ? "" : currentText
    }

    const input = document.createElement("input")
    input.type = this.typeValue
    if (this.typeValue === "number") {
      input.step = this.stepValue
      input.min  = this.minValue
    }
    input.value = currentValue
    input.className = "w-32 border border-blue-500 rounded px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-300"
    input.dataset.action = "blur->cell-edit#save keydown.enter->cell-edit#save keydown.escape->cell-edit#cancel"

    this.displayTarget.classList.add("hidden")
    this.element.appendChild(input)
    input.focus()
    // <input type="date"> does not support select(); guard it.
    if (this.typeValue !== "date") input.select()
  }

  async save(event) {
    const input = this.element.querySelector("input")
    if (!input) return
    if (event.type === "keydown" && event.key === "Enter") event.preventDefault()

    if (input.dataset.saving === "1") return
    input.dataset.saving = "1"

    const body = new FormData()
    body.append("authenticity_token", document.querySelector('meta[name="csrf-token"]').content)
    body.append("_method", "patch")
    body.append(`${this.paramValue}[${this.fieldValue}]`, input.value)

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        body,
        headers: { "Accept": "text/vnd.turbo-stream.html" }
      })

      // If the session expired (or any other 30x), fetch silently follows
      // the redirect and returns a 200 HTML page — NOT a Turbo Stream.
      // Navigate to the final URL so Devise can handle re-auth properly.
      if (response.redirected) {
        window.Turbo.visit(response.url)
        return
      }

      const contentType = response.headers.get("Content-Type") || ""
      const isTurboStream = contentType.includes("turbo-stream")

      if (response.ok && isTurboStream) {
        const text = await response.text()
        window.Turbo.renderStreamMessage(text)
      } else {
        this._markFailed(input)
      }
    } catch (e) {
      this._markFailed(input)
    }
  }

  _markFailed(input) {
    input.dataset.saving = ""
    input.classList.remove("border-blue-500")
    input.classList.add("border-red-500", "bg-red-50")
    input.focus()
  }

  cancel() {
    const input = this.element.querySelector("input")
    if (input) input.remove()
    this.displayTarget.classList.remove("hidden")
  }
}
```

- [ ] **Step 2: Confirm existing product_variant editing still works**

Run: `bundle exec rspec spec/requests/product_variants_spec.rb`
Expected: PASS (server side unchanged; the `param` default `"product_variant"` preserves the existing markup which omits `data-cell-edit-param-value`).

> The `product_variants` index view markup currently omits `data-cell-edit-param-value`, so it relies on the `"product_variant"` default — do not remove that default.

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/cell_edit_controller.js
git commit -m "feat: cell_edit_controller supports text/date inputs + configurable param"
```

---

## Task 13: Shipping rate cards index UI (full views + partials)

**Files:**
- Replace: `app/views/shipping_rate_card_versions/index.html.erb`
- Create: `app/views/shipping_rate_card_versions/_new_version_form.html.erb`
- Create: `app/views/shipping_rate_card_versions/_version.html.erb`
- Replace: `app/views/shipping_rate_card_versions/update.turbo_stream.erb`
- Create: `app/views/shipping_rate_card_rates/_rate.html.erb`
- Replace: `app/views/shipping_rate_card_rates/update.turbo_stream.erb`

> Each version card renders with `dom_id(version)`. Each rate row renders with `dom_id(rate)`. Inline-editable cells use the `cell-edit` controller with the appropriate `param` and `type`. New-version and new-band forms are owner-only `form_with` POSTs. Non-owners see read-only cells (no `data-controller`, no forms, no delete buttons).

- [ ] **Step 1: Write `index.html.erb`**

`app/views/shipping_rate_card_versions/index.html.erb`:

```erb
<div class="max-w-5xl mx-auto px-4 py-6">
  <h1 class="text-2xl font-semibold text-gray-900 mb-4"><%= t("shipping_rate_cards.title") %></h1>

  <%# Filters %>
  <%= form_with url: shipping_rate_card_versions_path, method: :get, local: true,
                class: "flex items-end gap-4 mb-6" do %>
    <label class="text-sm text-gray-700">
      <%= t("shipping_rate_cards.filter_country") %>
      <select name="country_code" onchange="this.form.requestSubmit()"
              class="block mt-1 border border-gray-300 rounded px-2 py-1 text-sm">
        <option value=""><%= t("shipping_rate_cards.filter_all") %></option>
        <% @countries.each do |c| %>
          <option value="<%= c %>" <%= "selected" if @selected_country == c %>><%= c %></option>
        <% end %>
      </select>
    </label>
    <label class="text-sm text-gray-700">
      <%= t("shipping_rate_cards.filter_service") %>
      <select name="service_type" onchange="this.form.requestSubmit()"
              class="block mt-1 border border-gray-300 rounded px-2 py-1 text-sm">
        <option value=""><%= t("shipping_rate_cards.filter_all") %></option>
        <% @services.each do |s| %>
          <option value="<%= s %>" <%= "selected" if @selected_service == s %>><%= s %></option>
        <% end %>
      </select>
    </label>
  <% end %>

  <% if current_membership&.owner? %>
    <%= render "new_version_form" %>
  <% end %>

  <div id="versions" class="space-y-6">
    <% if @versions.empty? %>
      <p class="text-sm text-gray-500"><%= t("shipping_rate_cards.empty") %></p>
    <% else %>
      <% @versions.each do |version| %>
        <%= render "version", version: version %>
      <% end %>
    <% end %>
  </div>
</div>
```

- [ ] **Step 2: Write `_new_version_form.html.erb`**

`app/views/shipping_rate_card_versions/_new_version_form.html.erb`:

```erb
<div class="bg-white border border-gray-200 rounded-lg shadow-sm p-5 mb-6">
  <h2 class="text-sm font-medium text-gray-700 mb-3"><%= t("shipping_rate_cards.new_version_title") %></h2>
  <%= form_with url: shipping_rate_card_versions_path, method: :post, local: true,
                class: "grid grid-cols-2 md:grid-cols-3 gap-3 items-end" do %>
    <label class="text-sm text-gray-700"><%= t("shipping_rate_cards.columns.name") %>
      <input type="text" name="shipping_rate_card_version[name]" required
             class="block w-full mt-1 border border-gray-300 rounded px-2 py-1 text-sm">
    </label>
    <label class="text-sm text-gray-700"><%= t("shipping_rate_cards.columns.country") %>
      <input type="text" name="shipping_rate_card_version[country_code]" required maxlength="2"
             class="block w-full mt-1 border border-gray-300 rounded px-2 py-1 text-sm uppercase">
    </label>
    <label class="text-sm text-gray-700"><%= t("shipping_rate_cards.columns.service") %>
      <input type="text" name="shipping_rate_card_version[service_type]" required
             class="block w-full mt-1 border border-gray-300 rounded px-2 py-1 text-sm">
    </label>
    <label class="text-sm text-gray-700"><%= t("shipping_rate_cards.columns.effective_from") %>
      <input type="date" name="shipping_rate_card_version[effective_from]" required
             class="block w-full mt-1 border border-gray-300 rounded px-2 py-1 text-sm">
    </label>
    <label class="text-sm text-gray-700"><%= t("shipping_rate_cards.columns.effective_to") %>
      <input type="date" name="shipping_rate_card_version[effective_to]"
             class="block w-full mt-1 border border-gray-300 rounded px-2 py-1 text-sm">
    </label>
    <div>
      <button type="submit"
              class="px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700">
        <%= t("shipping_rate_cards.create_version") %>
      </button>
    </div>
  <% end %>
</div>
```

- [ ] **Step 3: Write `_version.html.erb`**

`app/views/shipping_rate_card_versions/_version.html.erb`:

```erb
<% owner = current_membership&.owner? %>
<div id="<%= dom_id(version) %>" class="bg-white border border-gray-200 rounded-lg shadow-sm">
  <%# Header row %>
  <div class="flex flex-wrap items-center gap-3 px-5 py-3 border-b border-gray-100 text-sm">
    <% if owner %>
      <%= tag.span class: "font-medium text-gray-900",
            data: { controller: "cell-edit", "cell-edit-url-value": shipping_rate_card_version_path(version),
                    "cell-edit-param-value": "shipping_rate_card_version", "cell-edit-field-value": "name",
                    "cell-edit-type-value": "text" } do %>
        <%= tag.span version.name, data: { "cell-edit-target": "display", action: "click->cell-edit#startEdit" } %>
      <% end %>
      <%= tag.span class: "text-gray-600",
            data: { controller: "cell-edit", "cell-edit-url-value": shipping_rate_card_version_path(version),
                    "cell-edit-param-value": "shipping_rate_card_version", "cell-edit-field-value": "country_code",
                    "cell-edit-type-value": "text" } do %>
        <%= tag.span version.country_code, data: { "cell-edit-target": "display", action: "click->cell-edit#startEdit" } %>
      <% end %>
      <%= tag.span class: "text-gray-600",
            data: { controller: "cell-edit", "cell-edit-url-value": shipping_rate_card_version_path(version),
                    "cell-edit-param-value": "shipping_rate_card_version", "cell-edit-field-value": "service_type",
                    "cell-edit-type-value": "text" } do %>
        <%= tag.span version.service_type, data: { "cell-edit-target": "display", action: "click->cell-edit#startEdit" } %>
      <% end %>
      <%= tag.span class: "text-gray-600",
            data: { controller: "cell-edit", "cell-edit-url-value": shipping_rate_card_version_path(version),
                    "cell-edit-param-value": "shipping_rate_card_version", "cell-edit-field-value": "effective_from",
                    "cell-edit-type-value": "date" } do %>
        <%= tag.span version.effective_from, data: { "cell-edit-target": "display", action: "click->cell-edit#startEdit" } %>
      <% end %>
      <span class="text-gray-400">→</span>
      <%= tag.span class: "text-gray-600",
            data: { controller: "cell-edit", "cell-edit-url-value": shipping_rate_card_version_path(version),
                    "cell-edit-param-value": "shipping_rate_card_version", "cell-edit-field-value": "effective_to",
                    "cell-edit-type-value": "date" } do %>
        <%= tag.span (version.effective_to || "—"), data: { "cell-edit-target": "display", action: "click->cell-edit#startEdit" } %>
      <% end %>
      <%= button_to "🗑", shipping_rate_card_version_path(version), method: :delete,
            form: { class: "ml-auto", data: { turbo_confirm: t("shipping_rate_cards.version_deleted") } },
            class: "text-gray-400 hover:text-red-600" %>
    <% else %>
      <span class="font-medium text-gray-900"><%= version.name %></span>
      <span class="text-gray-600"><%= version.country_code %></span>
      <span class="text-gray-600"><%= version.service_type %></span>
      <span class="text-gray-600"><%= version.effective_from %></span>
      <span class="text-gray-400">→</span>
      <span class="text-gray-600"><%= version.effective_to || "—" %></span>
    <% end %>
  </div>

  <%# Rate bands table %>
  <table class="w-full text-sm">
    <thead>
      <tr class="text-left text-gray-500 border-b border-gray-100">
        <th class="px-5 py-2"><%= t("shipping_rate_cards.columns.weight_min") %></th>
        <th class="px-5 py-2"><%= t("shipping_rate_cards.columns.weight_max") %></th>
        <th class="px-5 py-2"><%= t("shipping_rate_cards.columns.per_kg") %></th>
        <th class="px-5 py-2"><%= t("shipping_rate_cards.columns.flat_fee") %></th>
        <th class="px-5 py-2"></th>
      </tr>
    </thead>
    <tbody id="<%= dom_id(version, :rates) %>">
      <% version.rates.order(:weight_min_kg).each do |rate| %>
        <%= render "shipping_rate_card_rates/rate", version: version, rate: rate %>
      <% end %>
    </tbody>
    <% if owner %>
      <tfoot>
        <tr class="border-t border-gray-100">
          <td colspan="5" class="px-5 py-3">
            <%= form_with url: shipping_rate_card_version_rates_path(version), method: :post, local: true,
                          class: "flex flex-wrap items-end gap-2" do %>
              <input type="number" step="0.001" min="0" name="shipping_rate_card_rate[weight_min_kg]"
                     placeholder="<%= t('shipping_rate_cards.columns.weight_min') %>" required
                     class="w-24 border border-gray-300 rounded px-2 py-1 text-sm">
              <input type="number" step="0.001" min="0" name="shipping_rate_card_rate[weight_max_kg]"
                     placeholder="<%= t('shipping_rate_cards.columns.weight_max') %>" required
                     class="w-24 border border-gray-300 rounded px-2 py-1 text-sm">
              <input type="number" step="0.01" min="0" name="shipping_rate_card_rate[per_kg_rate_cny]"
                     placeholder="<%= t('shipping_rate_cards.columns.per_kg') %>" required
                     class="w-24 border border-gray-300 rounded px-2 py-1 text-sm">
              <input type="number" step="0.01" min="0" name="shipping_rate_card_rate[flat_fee_cny]"
                     placeholder="<%= t('shipping_rate_cards.columns.flat_fee') %>" value="0" required
                     class="w-24 border border-gray-300 rounded px-2 py-1 text-sm">
              <button type="submit"
                      class="px-3 py-1 text-sm bg-blue-600 text-white rounded hover:bg-blue-700">
                <%= t("shipping_rate_cards.add_band") %>
              </button>
            <% end %>
          </td>
        </tr>
      </tfoot>
    <% end %>
  </table>
</div>
```

- [ ] **Step 4: Write `shipping_rate_card_rates/_rate.html.erb`**

`app/views/shipping_rate_card_rates/_rate.html.erb`:

```erb
<% owner = current_membership&.owner? %>
<tr id="<%= dom_id(rate) %>" class="border-b border-gray-50">
  <% if owner %>
    <% {
         weight_min_kg: "0.001", weight_max_kg: "0.001", per_kg_rate_cny: "0.01", flat_fee_cny: "0.01"
       }.each do |field, step| %>
      <td class="px-5 py-2"
          data-controller="cell-edit"
          data-cell-edit-url-value="<%= shipping_rate_card_version_rate_path(version, rate) %>"
          data-cell-edit-param-value="shipping_rate_card_rate"
          data-cell-edit-field-value="<%= field %>"
          data-cell-edit-type-value="number"
          data-cell-edit-step-value="<%= step %>"
          data-cell-edit-min-value="0">
        <span data-cell-edit-target="display" data-action="click->cell-edit#startEdit">
          <%= rate.public_send(field) %>
        </span>
      </td>
    <% end %>
    <td class="px-5 py-2">
      <%= button_to "🗑", shipping_rate_card_version_rate_path(version, rate), method: :delete,
            form: { data: { turbo_confirm: t("shipping_rate_cards.rate_deleted") } },
            class: "text-gray-400 hover:text-red-600" %>
    </td>
  <% else %>
    <td class="px-5 py-2"><%= rate.weight_min_kg %></td>
    <td class="px-5 py-2"><%= rate.weight_max_kg %></td>
    <td class="px-5 py-2"><%= rate.per_kg_rate_cny %></td>
    <td class="px-5 py-2"><%= rate.flat_fee_cny %></td>
    <td class="px-5 py-2"></td>
  <% end %>
</tr>
```

- [ ] **Step 5: Replace the two `update.turbo_stream.erb` files with real ones**

`app/views/shipping_rate_card_versions/update.turbo_stream.erb`:

```erb
<%= turbo_stream.replace dom_id(@version) do %>
  <%= render "version", version: @version %>
<% end %>
```

`app/views/shipping_rate_card_rates/update.turbo_stream.erb`:

```erb
<%= turbo_stream.replace dom_id(@rate) do %>
  <%= render "shipping_rate_card_rates/rate", version: @version, rate: @rate %>
<% end %>
```

- [ ] **Step 6: Re-run the request specs to confirm the real views render**

Run: `bundle exec rspec spec/requests/shipping_rate_card_versions_spec.rb spec/requests/shipping_rate_card_rates_spec.rb`
Expected: PASS (index renders the version partial; PATCH renders the real Turbo Stream).

- [ ] **Step 7: Commit**

```bash
git add app/views/shipping_rate_card_versions app/views/shipping_rate_card_rates
git commit -m "feat: shipping rate cards inline-editing UI (versions + bands)"
```

---

## Task 14: Shop detail page — default service type form

**Files:**
- Modify: `app/views/shopify_stores/show.html.erb` (after the Cost FX rate section, ~line 94)

> No new spec — covered by the Task 11 request spec (server) and exercised manually. The markup mirrors the existing Cost FX rate block verbatim in structure.

- [ ] **Step 1: Add the service-type block**

In `app/views/shopify_stores/show.html.erb`, immediately after the closing `</div>` of the Cost FX rate section (the block ending around line 94), add:

```erb
<div class="mt-6 bg-white shadow-sm rounded-lg border border-gray-200 p-6">
  <h2 class="text-lg font-medium text-gray-900"><%= t("shopify_stores.default_service_type") %></h2>
  <p class="mt-1 text-sm text-gray-500"><%= t("shopify_stores.default_service_hint") %></p>
  <% if current_membership&.owner? %>
    <%= form_with url: shopify_store_path(@shopify_store), method: :patch, local: true,
                  class: "mt-3 flex items-center gap-2" do %>
      <input type="text"
             name="shopify_store[default_service_type]"
             id="shopify_store_default_service_type"
             value="<%= @shopify_store.default_service_type %>"
             list="service_type_options"
             placeholder="standard_with_battery"
             class="w-64 border border-gray-300 rounded px-2 py-1 text-sm">
      <datalist id="service_type_options">
        <% current_company.shipping_rate_card_versions.distinct.pluck(:service_type).sort.each do |st| %>
          <option value="<%= st %>"></option>
        <% end %>
      </datalist>
      <button type="submit"
              class="px-3 py-1 text-sm bg-blue-600 text-white rounded hover:bg-blue-700">
        <%= t("shopify_stores.save_service_type") %>
      </button>
    <% end %>
  <% else %>
    <p class="mt-3 text-sm text-gray-700">
      <strong><%= @shopify_store.default_service_type.presence || "—" %></strong>
      <span class="text-xs text-gray-500 ml-2"><%= t("shopify_stores.service_type_owner_only") %></span>
    </p>
  <% end %>
</div>
```

- [ ] **Step 2: Verify the page renders**

Run: `bundle exec rspec spec/requests/shopify_stores_spec.rb`
Expected: PASS (GET show, if present, still renders; PATCH branch from Task 11 still green).

- [ ] **Step 3: Commit**

```bash
git add app/views/shopify_stores/show.html.erb
git commit -m "feat: shop detail default_service_type form (owner-only)"
```

---

## Task 15: Dashboard metrics — shipping aggregation

**Files:**
- Modify: `app/services/dashboard_metrics_service.rb`
- Test: `spec/services/dashboard_metrics_service_spec.rb` (extend)

- [ ] **Step 1: Write the failing spec additions**

Add to `spec/services/dashboard_metrics_service_spec.rb`. IMPORTANT: `aggregate_metrics` is `private` — drive the service through its public interface `described_class.new(scope, start_date:, end_date:).call`, which returns `{ current:, previous:, ... }`. The scope must respond to `shopify_stores`/`ad_accounts` (both `User` and `Company` do; the existing spec passes `user`). Use an explicit custom date range because the orders are dated April 2026 (not within any `range_key` like "today").

```ruby
  describe "shipping cost aggregation" do
    let(:user) { create(:user) }
    let(:company) { user.companies.first }
    let(:store) { create(:shopify_store, user: user, company: company, timezone: "UTC") }
    let(:customer) { create(:customer, shopify_store: store) }

    def order_on(day, estimated: nil, actual: nil)
      create(:order, customer: customer, shopify_store: store,
             ordered_at: store.active_timezone.local(2026, 4, day, 12),
             estimated_shipping_cost: estimated, actual_shipping_cost: actual, total_price: 100)
    end

    # Public interface: returns the {current:, previous:} hash; read :current.
    subject(:metrics) do
      described_class.new(company, start_date: "2026-04-01", end_date: "2026-04-30").call.fetch(:current)
    end

    it "sums COALESCE(actual, estimated, 0) into :shipping_cost" do
      order_on(5, estimated: 10, actual: nil)
      order_on(6, estimated: 10, actual: 7)   # actual wins → 7
      order_on(7, estimated: nil, actual: nil) # 0
      expect(metrics[:shipping_cost]).to eq(17)
    end

    it "reports coverage breakdown" do
      order_on(5, estimated: 10, actual: nil)  # estimated-only
      order_on(6, estimated: 10, actual: 7)    # actual
      order_on(7, estimated: nil, actual: nil) # missing
      expect(metrics[:shipping_coverage_actual_pct]).to eq(33.3)
      expect(metrics[:shipping_coverage_estimated_pct]).to eq(33.3)
      expect(metrics[:shipping_coverage_pct]).to eq(66.7)
    end

    it "subtracts shipping from net_profit" do
      order_on(5, estimated: 10, actual: nil)
      # No daily metrics → revenue/cogs/ad_spend are 0, so net_profit = -shipping.
      expect(metrics[:net_profit]).to eq(metrics[:gross_profit] - metrics[:shipping_cost] - metrics[:ad_spend])
    end
  end
```

> The existing spec instantiates via `described_class.new(user, range_key: "today").call` and reads `result[:current][:...]`. We pass `company` (it `respond_to?(:shopify_stores)` and `:ad_accounts`) with a custom date window. The shipping aggregation queries `Order` directly by store + `ordered_at`, so it does NOT need any `ShopifyDailyMetric`/`AdDailyMetric` rows.

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/dashboard_metrics_service_spec.rb -e "shipping cost aggregation"`
Expected: FAIL — `metrics[:shipping_cost]` is nil.

- [ ] **Step 3: Extend the service**

In `app/services/dashboard_metrics_service.rb`, inside `aggregate_metrics`, after the `cogs, coverage = aggregate_cogs(store_scope, range)` line, add:

```ruby
  shipping_total, shipping_breakdown = aggregate_shipping(store_scope, range)
```

Change the net-profit computation. Replace:

```ruby
  net_profit = gross_profit - ad_spend
```

with:

```ruby
  net_profit = gross_profit - shipping_total - ad_spend
```

Add these keys to the returned hash (next to `cogs_coverage_pct`):

```ruby
    shipping_cost: shipping_total,
    shipping_coverage_pct: shipping_breakdown[:coverage],
    shipping_coverage_actual_pct: shipping_breakdown[:actual],
    shipping_coverage_estimated_pct: shipping_breakdown[:estimated_only],
```

Add the private method (next to `aggregate_cogs`):

```ruby
  def aggregate_shipping(store_scope, range)
    total = BigDecimal("0")
    count_total = 0
    count_actual = 0
    count_estimated_only = 0

    store_scope.find_each do |store|
      tz = store.active_timezone
      start_utc = tz.local(range.first.year, range.first.month, range.first.day).utc
      end_utc   = tz.local(range.last.year,  range.last.month,  range.last.day).end_of_day.utc

      orders = Order.where(shopify_store_id: store.id, ordered_at: start_utc..end_utc)

      total += orders.sum("COALESCE(actual_shipping_cost, estimated_shipping_cost, 0)")
      count_total          += orders.count
      count_actual         += orders.where.not(actual_shipping_cost: nil).count
      count_estimated_only += orders.where(actual_shipping_cost: nil).where.not(estimated_shipping_cost: nil).count
    end

    pct = ->(n) { count_total > 0 ? (n.to_f / count_total * 100).round(1) : nil }
    [
      total,
      {
        coverage:       pct.call(count_actual + count_estimated_only),
        actual:         pct.call(count_actual),
        estimated_only: pct.call(count_estimated_only)
      }
    ]
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/dashboard_metrics_service_spec.rb`
Expected: PASS (whole file — confirm the net_profit formula change did not break existing examples; if an existing example asserted `net_profit == gross_profit - ad_spend` with no orders, it still holds since shipping_total is 0).

- [ ] **Step 5: Commit**

```bash
git add app/services/dashboard_metrics_service.rb spec/services/dashboard_metrics_service_spec.rb
git commit -m "feat: aggregate shipping cost into dashboard net profit + coverage"
```

---

## Task 16: Dashboard view — shipping card + coverage line

**Files:**
- Modify: `app/views/dashboard/show.html.erb`

> No dedicated spec — the Task 15 service spec covers the numbers; this is presentation. The shipping card uses `invert_color: true` (higher shipping = worse), mirroring the Ad Spend card.

- [ ] **Step 1: Add the Shipping Cost card**

In `app/views/dashboard/show.html.erb`, inside the metric-cards grid, add a card after the Net Profit card (after line 122, before the grid's closing `</div>` at line 123):

```erb
      <%# Shipping Cost %>
      <%= render "dashboard/metric_card",
          title: t("dashboard.shipping_cost"),
          value: number_to_currency(@metrics[:current][:shipping_cost]),
          previous: @metrics[:previous][:shipping_cost],
          current_raw: @metrics[:current][:shipping_cost],
          invert_color: true %>
```

- [ ] **Step 2: Add the shipping coverage line**

Immediately after the existing COGS-coverage `<p>` block (the `<% if @metrics[:current][:cogs_coverage_pct] ... %>` block ending at line 129), add:

```erb
    <% if @metrics[:current][:shipping_coverage_pct] && @metrics[:current][:shipping_coverage_pct] < 100 %>
      <p class="mt-1 text-xs text-gray-500">
        <%= t("dashboard.shipping_coverage") %>: <%= @metrics[:current][:shipping_coverage_pct] %>%
        (<%= t("dashboard.shipping_coverage_actual") %>: <%= @metrics[:current][:shipping_coverage_actual_pct] %>%
        · <%= t("dashboard.shipping_coverage_estimated") %>: <%= @metrics[:current][:shipping_coverage_estimated_pct] %>%)
      </p>
    <% end %>
```

- [ ] **Step 3: Verify the dashboard renders**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb` (if present) or `spec/system` dashboard spec.
Expected: PASS / no `translation missing` and no `nil` errors. If no dashboard request spec exists, manually confirm via `bin/dev` that `/` renders with the new card.

- [ ] **Step 4: Commit**

```bash
git add app/views/dashboard/show.html.erb
git commit -m "feat: dashboard shipping cost card + coverage breakdown line"
```

---

## Task 17: System spec — create version, add band, inline edit

**Files:**
- Test: `spec/system/shipping_rate_cards_spec.rb`

> Verifies the full UI loop end-to-end, including the extended `cell_edit_controller.js` (the only coverage for the JS change). Read an existing `spec/system/*_spec.rb` first to match the driver setup (`type: :system`, `js: true`, login helper).

- [ ] **Step 1: Write the system spec**

`spec/system/shipping_rate_cards_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Shipping rate cards", type: :system, js: true do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }

  before do
    driven_by(:selenium_chrome_headless)
    login_as(owner, scope: :user) # Warden::Test::Helpers; mirror existing system specs
  end

  it "creates a version, adds a band, and inline-edits a cell" do
    visit shipping_rate_card_versions_path

    # Create a version
    fill_in "shipping_rate_card_version[name]", with: "Q2 2026 US Battery"
    fill_in "shipping_rate_card_version[country_code]", with: "US"
    fill_in "shipping_rate_card_version[service_type]", with: "standard_with_battery"
    fill_in "shipping_rate_card_version[effective_from]", with: "2026-04-01"
    click_button t("shipping_rate_cards.create_version")

    expect(page).to have_content("Q2 2026 US Battery")

    # Add a weight band inside the version
    within("##{ActionView::RecordIdentifier.dom_id(ShippingRateCardVersion.last)}") do
      fill_in "shipping_rate_card_rate[weight_min_kg]", with: "0.05"
      fill_in "shipping_rate_card_rate[weight_max_kg]", with: "0.2"
      fill_in "shipping_rate_card_rate[per_kg_rate_cny]", with: "92.0"
      fill_in "shipping_rate_card_rate[flat_fee_cny]", with: "25.0"
      click_button t("shipping_rate_cards.add_band")
    end

    expect(page).to have_content("92.0")

    # Inline-edit the per_kg cell
    rate = ShippingRateCardRate.last
    within("##{ActionView::RecordIdentifier.dom_id(rate)}") do
      find("span[data-cell-edit-target='display']", text: "92.0").click
      input = find("input")
      input.set("100.0")
      input.native.send_keys(:enter)
    end

    expect(page).to have_content("100.0")
    expect(rate.reload.per_kg_rate_cny).to eq(100.0)
  end
end
```

> If the existing system specs use a different login helper (e.g. a `sign_in` system helper or a UI login flow) or a different driver, match that instead of `login_as`. The assertions on `dom_id` and the cell-edit interaction are the important parts.

- [ ] **Step 2: Run the system spec**

Run: `bundle exec rspec spec/system/shipping_rate_cards_spec.rb`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add spec/system/shipping_rate_cards_spec.rb
git commit -m "test: system spec for shipping rate cards create/add/inline-edit"
```

---

## Task 18: Full suite + lint gate

**Files:** none (verification only)

- [ ] **Step 1: Run the full suite**

Run: `bundle exec rspec`
Expected: all green; coverage ≥ 95% (CLAUDE.md gate).

- [ ] **Step 2: Lint and security**

Run: `bin/rubocop && bin/brakeman --no-pager`
Expected: no offenses; no new Brakeman warnings.

- [ ] **Step 3: Fix any issues, then commit**

```bash
git add -A
git commit -m "chore: rubocop + brakeman clean for shipping cost feature"
```

---

## Self-Review

**Spec coverage:**
- ✅ Estimated cost from rate cards → `orders.estimated_shipping_cost` (Tasks 1, 5, 6)
- ✅ Reserved `orders.actual_shipping_cost`, no importer (Task 1; never populated — asserted in Tasks 6, 7)
- ✅ `Order#effective_shipping_cost = actual ?? estimated` (Task 4)
- ✅ Dashboard `COALESCE(actual, estimated, 0)` + coverage breakdown (Tasks 15, 16)
- ✅ Named versions, auditable (Tasks 1, 2, 13)
- ✅ Version fallback semantics — newest past version, no manual `effective_to` (Task 2 `.lookup` + specs)
- ✅ Inline editing + add-row, no CSV (Tasks 12, 13)
- ✅ Owner-only gate (Tasks 9, 10, 11; page-view via PERMISSION_KEY_MAP Task 8)
- ✅ Two-level schema `versions` + `rates` (Tasks 1–3)
- ✅ Sync integration frozen-once-set (Task 6); backfill (Task 7)
- ✅ Shop-level `default_service_type` (Tasks 1, 11, 14)
- ✅ Routes, authz mapping, i18n × 3 locales (Task 8)
- ✅ All test buckets from the spec's Testing section (model/service/request/system/dashboard)

**Corrections applied vs. spec text:**
- `Company` association is `has_many :shipping_rate_card_versions` (spec sample said `:shipping_rate_cards`; the table and controller use the versions name). Flagged in Task 4.
- `cell_edit_controller.js` needed a configurable `param` value, not only `type` — the original hardcoded `product_variant[...]`. Added in Task 12 with a back-compat default.
- Controller stub views are created in Tasks 9/10 to avoid `MissingTemplate`, then fully replaced in Task 13.

**Type/name consistency:** model attrs, scope names (`for_lookup`, `for_weight`, `.lookup`), service entrypoint (`ShippingCostCalculator.estimate`), and metric keys (`shipping_cost`, `shipping_coverage_pct`, `shipping_coverage_actual_pct`, `shipping_coverage_estimated_pct`) are used identically across tasks.

**Codex adversarial-review fixes applied (verified against the real codebase):**
- BLOCKER — `DashboardMetricsService#aggregate_metrics` is `private`; the public API is `new(scope, start_date:, end_date:).call → { current:, previous: }`. Task 15 spec rewritten to use it (was calling the private method directly).
- Task 6 — snapshot call moved to BETWEEN `sync_line_items` and `sync_fulfillments` (matches the spec; avoids losing the snapshot if the live `fetch_fulfillments` API call fails).
- Task 5 — `ShippingCostCalculator` hardened: guard `@order.ordered_at` (nullable column → would raise `NoMethodError`) and return `nil` when ANY line item lacks a weight (the spec's `(weight_grams || 0)` would silently underestimate partial-weight orders). Added two test cases.
- Task 8 — added sidebar nav link + `nav.shipping_rate_cards` i18n keys (the page was reachable by URL only).

**Codex findings reviewed and DISMISSED (Codex was mistaken):**
- "Net Margin card / missing `dashboard.net_margin` key" — this plan never adds a Net Margin card; `net_margin_pct` already exists in the metrics hash and inherits the new `net_profit` formula automatically (Task 15). No view/i18n change needed.
- "cell_edit default `param` already redundant" — verified `app/views/product_variants/_row.html.erb` does NOT pass `data-cell-edit-param-value`; the `"product_variant"` default in Task 12 is load-bearing and correct.

**Confirmed-correct by review (no change):** FX direction (`cny / cost_fx_rate`), nested route helpers, `PERMISSION_KEY_MAP` mapping, migration timestamp ordering (latest existing is `20260531100001`), calculator rounding (`50.6 / 7.0 → 7.23`), global `RecordNotFound → 404`, and factory availability.

**Known adaptation points (call out at execution time, not placeholders):** the existing-file specs (`sync_all_orders_service_spec`, `backfill_order_line_items_service_spec`, `dashboard_metrics_service_spec`, system-spec login) must mirror each file's established setup conventions — each task says exactly what to mirror and what the behavioral assertions must be.
