# UK Remote-Area Surcharge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a versioned, postcode-matched remote-area surcharge (UK Royal Mail Area 2 = ¥17, Area 3 = ¥10) to the shipping ESTIMATE, per parcel, so it is on the same basis as the actual bill's `remote_area_fee_cny`.

**Architecture:** A new `ShippingRemoteAreaVersion` (effective-dated, one lookup per order date, mirroring `ShippingRateCardVersion`) owns `ShippingRemoteAreaRule` rows (normalized postcode range → surcharge + area label). `PostalNormalizer` gains GB support. `ShippingCostCalculator` resolves the surcharge from the order's destination postcode and adds it to every priced parcel (like the existing ¥2 operation fee). A config page mirrors the rate-card-versions page with batch paste import.

**Tech Stack:** Rails 8.1, PostgreSQL (UUID PKs), RSpec + FactoryBot (no mocks, real DB, 95%+ line coverage), Hotwire/Turbo, Tailwind.

## Global Constraints

- All table PKs are UUIDs (`id: :uuid, default: -> { "gen_random_uuid()" }`).
- Money is BigDecimal, `decimal(10,2)`; surcharge `>= 0`.
- Version lookup semantics MUST match `ShippingRateCardVersion.lookup` exactly: `effective_from <= on_date AND (effective_to IS NULL OR effective_to >= on_date)`, `order(effective_from: :desc).first`. `on_date = order.ordered_at.to_date`.
- Surcharge is PER PARCEL (over-max split → ×parcel_count), matching the ¥2 op fee and the actual `remote_area_fee_cny` per parcel.
- Surcharge feeds the ESTIMATE only; the actual keeps using the imported `parcels.remote_area_fee_cny`.
- Postcode resolution is shipping-then-billing (same as `ShippingCostCalculator#destination_address` / `postal_from_order`).
- i18n keys in all three locales: `config/locales/en.yml`, `zh-CN.yml`, `zh-TW.yml`. No duplicate top-level keys.
- Owner-only writes; page visible to members with the `shipping` page permission (mirror `ShippingRateCardVersionsController`).

## File Structure

- `app/services/postal_normalizer.rb` — MODIFY: add GB normalize/range + `"GB"` to `SUPPORTED_COUNTRIES`.
- `db/migrate/*_create_shipping_remote_area_versions.rb`, `*_create_shipping_remote_area_rules.rb` — CREATE.
- `app/models/shipping_remote_area_version.rb`, `app/models/shipping_remote_area_rule.rb` — CREATE.
- `spec/factories/shipping_remote_area_versions.rb`, `spec/factories/shipping_remote_area_rules.rb` — CREATE.
- `app/services/shipping_cost_calculator.rb` — MODIFY: `Basis` carries surcharge; `resolve` resolves it; `cost_cny_for` adds it per parcel.
- `app/services/remote_area_rule_importer.rb` — CREATE: batch paste importer.
- `app/controllers/shipping_remote_area_versions_controller.rb`, `app/controllers/shipping_remote_area_rules_controller.rb` — CREATE.
- `app/views/shipping_remote_area_versions/index.html.erb` (+ partials) — CREATE.
- `app/views/parcels/index.html.erb` — MODIFY: basis-line surcharge chip.
- `config/routes.rb`, `app/views/shared/_sidebar.html.erb`, locales — MODIFY.

---

### Task 1: GB postcode normalization in PostalNormalizer

**Files:**
- Modify: `app/services/postal_normalizer.rb`
- Test: `spec/services/postal_normalizer_spec.rb`

**Interfaces:**
- Produces: `PostalNormalizer.normalize("GB", raw) -> "AB35"|"BT01"|nil`, `PostalNormalizer.range_for("GB", token) -> [start,end]|nil`, and `"GB"` added to `SUPPORTED_COUNTRIES`.
- Key format: `<uppercase letters 1–2><2-digit zero-padded district>`. `"IV1 1AA"`→`"IV01"`, `"AB35"`→`"AB35"`, `"BT1"`→`"BT01"`, `"BT10"`→`"BT10"`, `"GY1"`→`"GY01"`.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/services/postal_normalizer_spec.rb — add a GB describe block
describe "GB" do
  it "normalizes an outward code with a space to letters + zero-padded 2-digit district" do
    expect(PostalNormalizer.normalize("GB", "IV1 1AA")).to eq("IV01")
    expect(PostalNormalizer.normalize("GB", "ab35")).to eq("AB35")
    expect(PostalNormalizer.normalize("GB", "BT1")).to eq("BT01")
    expect(PostalNormalizer.normalize("GB", "BT10")).to eq("BT10") # distinct from BT01
    expect(PostalNormalizer.normalize("GB", "GY1")).to eq("GY01")
  end

  it "returns nil for blank or unparseable input" do
    expect(PostalNormalizer.normalize("GB", "")).to be_nil
    expect(PostalNormalizer.normalize("GB", "!!")).to be_nil
  end

  it "expands a single outward code into a point range" do
    expect(PostalNormalizer.range_for("GB", "AB35")).to eq(%w[AB35 AB35])
  end

  it "expands a bare letter area into the whole district span" do
    expect(PostalNormalizer.range_for("GB", "IV")).to eq(%w[IV00 IV99])
  end

  it "expands a district range token" do
    expect(PostalNormalizer.range_for("GB", "KA27-28")).to eq(%w[KA27 KA28])
    expect(PostalNormalizer.range_for("GB", "PA20-49")).to eq(%w[PA20 PA49])
  end

  it "returns nil for a malformed token" do
    expect(PostalNormalizer.range_for("GB", "1234")).to be_nil
  end

  it "lists GB as supported" do
    expect(PostalNormalizer::SUPPORTED_COUNTRIES).to include("GB")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/services/postal_normalizer_spec.rb -e GB`
Expected: FAIL (GB not handled; `normalize` returns nil, `SUPPORTED_COUNTRIES` lacks GB).

- [ ] **Step 3: Implement**

```ruby
# app/services/postal_normalizer.rb
class PostalNormalizer
  SUPPORTED_COUNTRIES = %w[AU CA GB].freeze

  def self.normalize(country, raw)
    return nil if raw.blank?
    case country
    when "AU" then normalize_au(raw)
    when "CA" then normalize_ca(raw)
    when "GB" then normalize_gb(raw)
    end
  end

  def self.range_for(country, token)
    case country
    when "AU" then range_au(token)
    when "CA" then range_ca(token)
    when "GB" then range_gb(token)
    end
  end

  # ... keep existing AU/CA methods ...

  # UK outward code -> "<LETTERS><2-digit district>". Takes the part before the
  # first space, splits into leading letters (1–2) + trailing digits (1–2),
  # zero-pads the digits to 2 so BT1 ("BT01") and BT10 ("BT10") stay distinct
  # and comparable for range matching. A trailing letter (e.g. "EC1A") is
  # ignored — area matching only needs area + district.
  def self.normalize_gb(raw)
    outward = raw.to_s.strip.upcase.split(/\s+/).first.to_s
    m = outward.match(/\A([A-Z]{1,2})(\d{1,2})/)
    return nil unless m
    "#{m[1]}#{m[2].rjust(2, '0')}"
  end

  # Import token -> [start_key, end_key]:
  #   "AB35"     -> ["AB35","AB35"]      (single district)
  #   "IV"       -> ["IV00","IV99"]      (whole letter area)
  #   "KA27-28"  -> ["KA27","KA28"]      (district range, same letters)
  def self.range_gb(token)
    t = token.to_s.strip.upcase
    return nil if t.empty?

    if (m = t.match(/\A([A-Z]{1,2})(\d{1,2})-(\d{1,2})\z/))
      letters, a, b = m[1], m[2].rjust(2, "0"), m[3].rjust(2, "0")
      return nil if b < a
      return [ "#{letters}#{a}", "#{letters}#{b}" ]
    end

    if t.match?(/\A[A-Z]{1,2}\z/) # bare letter area
      return [ "#{t}00", "#{t}99" ]
    end

    v = normalize_gb(t) # single outward code
    v && [ v, v ]
  end

  private_class_method :normalize_au, :range_au, :normalize_ca, :range_ca,
                       :normalize_gb, :range_gb
end
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/services/postal_normalizer_spec.rb`
Expected: PASS (all, including existing AU/CA).

- [ ] **Step 5: Commit**

```bash
git add app/services/postal_normalizer.rb spec/services/postal_normalizer_spec.rb
git commit -m "feat(shipping): add GB postcode normalization to PostalNormalizer"
```

---

### Task 2: Remote-area version + rule models

**Files:**
- Create: `db/migrate/<ts>_create_shipping_remote_area_versions.rb`
- Create: `db/migrate/<ts>_create_shipping_remote_area_rules.rb`
- Create: `app/models/shipping_remote_area_version.rb`
- Create: `app/models/shipping_remote_area_rule.rb`
- Create: `spec/factories/shipping_remote_area_versions.rb`
- Create: `spec/factories/shipping_remote_area_rules.rb`
- Test: `spec/models/shipping_remote_area_version_spec.rb`, `spec/models/shipping_remote_area_rule_spec.rb`

**Interfaces:**
- Produces:
  - `ShippingRemoteAreaVersion.lookup(company:, country:, on_date:) -> version | nil`
  - `version.surcharge_for(key) -> rule | nil` (rule responds to `surcharge_cny`, `area_label`)
  - `belongs_to :company`; `has_many :rules, class_name: "ShippingRemoteAreaRule", dependent: :destroy, inverse_of: :version`
  - `ShippingRemoteAreaRule`: `version_id, postal_start, postal_end, surcharge_cny, area_label`

- [ ] **Step 1: Write migrations**

```ruby
# db/migrate/<ts>_create_shipping_remote_area_versions.rb
class CreateShippingRemoteAreaVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_remote_area_versions, id: :uuid do |t|
      t.uuid :company_id, null: false
      t.string :country_code, null: false
      t.string :name, null: false
      t.date :effective_from, null: false
      t.date :effective_to
      t.timestamps
    end
    add_index :shipping_remote_area_versions, [ :company_id, :country_code, :effective_from ],
              name: "idx_remote_area_versions_lookup"
  end
end
```

```ruby
# db/migrate/<ts>_create_shipping_remote_area_rules.rb
class CreateShippingRemoteAreaRules < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_remote_area_rules, id: :uuid do |t|
      t.uuid :version_id, null: false
      t.string :postal_start, null: false
      t.string :postal_end, null: false
      t.decimal :surcharge_cny, precision: 10, scale: 2, null: false
      t.string :area_label
      t.timestamps
    end
    add_index :shipping_remote_area_rules, [ :version_id, :postal_start ],
              name: "idx_remote_area_rules_lookup"
  end
end
```

- [ ] **Step 2: Migrate**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: both tables created; `db/schema.rb` updated.

- [ ] **Step 3: Write the failing model tests**

```ruby
# spec/models/shipping_remote_area_version_spec.rb
require "rails_helper"
RSpec.describe ShippingRemoteAreaVersion do
  let(:company) { create(:company) }

  it "requires name, country_code, effective_from" do
    v = ShippingRemoteAreaVersion.new(company: company)
    expect(v).not_to be_valid
    expect(v.errors.attribute_names).to include(:name, :country_code, :effective_from)
  end

  it "rejects effective_to before effective_from" do
    v = build(:shipping_remote_area_version, company: company,
              effective_from: Date.new(2026, 6, 1), effective_to: Date.new(2026, 5, 1))
    expect(v).not_to be_valid
  end

  describe ".lookup" do
    it "picks the latest effective_from on or before the date, honoring effective_to" do
      old = create(:shipping_remote_area_version, company: company, country_code: "GB",
                   effective_from: Date.new(2025, 1, 1), effective_to: nil)
      new = create(:shipping_remote_area_version, company: company, country_code: "GB",
                   effective_from: Date.new(2026, 6, 1), effective_to: nil)
      expect(described_class.lookup(company: company, country: "GB", on_date: Date.new(2026, 5, 10))).to eq(old)
      expect(described_class.lookup(company: company, country: "GB", on_date: Date.new(2026, 6, 1))).to eq(new)
    end

    it "returns nil before the earliest version" do
      create(:shipping_remote_area_version, company: company, country_code: "GB",
             effective_from: Date.new(2026, 1, 1))
      expect(described_class.lookup(company: company, country: "GB", on_date: Date.new(2025, 12, 31))).to be_nil
    end
  end

  describe "#surcharge_for" do
    it "returns the matching rule, preferring the most specific (highest postal_start)" do
      v = create(:shipping_remote_area_version, company: company, country_code: "GB")
      create(:shipping_remote_area_rule, version: v, postal_start: "IV00", postal_end: "IV99",
             surcharge_cny: 17, area_label: "area 2")
      point = create(:shipping_remote_area_rule, version: v, postal_start: "IV63", postal_end: "IV63",
                     surcharge_cny: 25, area_label: "special")
      expect(v.surcharge_for("IV63")).to eq(point)     # most specific wins
      expect(v.surcharge_for("IV01").surcharge_cny).to eq(17)
      expect(v.surcharge_for("BT01")).to be_nil
    end
  end
end
```

```ruby
# spec/models/shipping_remote_area_rule_spec.rb
require "rails_helper"
RSpec.describe ShippingRemoteAreaRule do
  it "requires postal_start, postal_end, surcharge_cny and a non-negative surcharge" do
    r = ShippingRemoteAreaRule.new
    expect(r).not_to be_valid
    r = build(:shipping_remote_area_rule, surcharge_cny: -1)
    expect(r).not_to be_valid
  end

  it "rejects postal_end before postal_start" do
    r = build(:shipping_remote_area_rule, postal_start: "IV99", postal_end: "IV00")
    expect(r).not_to be_valid
  end
end
```

- [ ] **Step 4: Write factories + models**

```ruby
# spec/factories/shipping_remote_area_versions.rb
FactoryBot.define do
  factory :shipping_remote_area_version do
    company
    sequence(:name) { |n| "Remote Area v#{n}" }
    country_code { "GB" }
    effective_from { Date.new(2026, 1, 1) }
    effective_to { nil }
  end
end
```

```ruby
# spec/factories/shipping_remote_area_rules.rb
FactoryBot.define do
  factory :shipping_remote_area_rule do
    association :version, factory: :shipping_remote_area_version
    postal_start { "IV00" }
    postal_end { "IV99" }
    surcharge_cny { 17 }
    area_label { "area 2" }
  end
end
```

```ruby
# app/models/shipping_remote_area_version.rb
class ShippingRemoteAreaVersion < ApplicationRecord
  belongs_to :company
  has_many :rules, class_name: "ShippingRemoteAreaRule",
                   foreign_key: :version_id, dependent: :destroy, inverse_of: :version

  validates :name, :country_code, :effective_from, presence: true
  validate :effective_to_after_from

  scope :for_lookup, ->(country:, on_date:) {
    where(country_code: country)
      .where("effective_from <= ?", on_date)
      .where("effective_to IS NULL OR effective_to >= ?", on_date)
      .order(effective_from: :desc)
  }

  def self.lookup(company:, country:, on_date:)
    where(company: company).for_lookup(country: country, on_date: on_date).first
  end

  # The matching rule for a normalized postal key, most specific first
  # (highest postal_start), mirroring ShippingZonePostalRule#zone_for.
  def surcharge_for(key)
    rules.where("postal_start <= :k AND postal_end >= :k", k: key)
         .order(postal_start: :desc).first
  end

  private

  def effective_to_after_from
    return unless effective_from && effective_to
    errors.add(:effective_to, "must be on or after effective_from") if effective_to < effective_from
  end
end
```

```ruby
# app/models/shipping_remote_area_rule.rb
class ShippingRemoteAreaRule < ApplicationRecord
  belongs_to :version, class_name: "ShippingRemoteAreaVersion", inverse_of: :rules

  validates :postal_start, :postal_end, presence: true
  validates :surcharge_cny, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validate :end_not_before_start

  private

  def end_not_before_start
    return unless postal_start && postal_end
    errors.add(:postal_end, "must be on or after postal_start") if postal_end < postal_start
  end
end
```

- [ ] **Step 5: Run tests**

Run: `bundle exec rspec spec/models/shipping_remote_area_version_spec.rb spec/models/shipping_remote_area_rule_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/migrate app/models/shipping_remote_area_version.rb app/models/shipping_remote_area_rule.rb spec/factories/shipping_remote_area_versions.rb spec/factories/shipping_remote_area_rules.rb spec/models/shipping_remote_area_version_spec.rb spec/models/shipping_remote_area_rule_spec.rb db/schema.rb
git commit -m "feat(shipping): add versioned remote-area surcharge models"
```

---

### Task 3: Estimate integration in ShippingCostCalculator

**Files:**
- Modify: `app/services/shipping_cost_calculator.rb`
- Test: `spec/services/shipping_cost_calculator_spec.rb`

**Interfaces:**
- Consumes: `ShippingRemoteAreaVersion.lookup(...)`, `.surcharge_for(key)`, `PostalNormalizer.normalize`.
- Produces: `Basis` exposes `remote_surcharge_cny` (BigDecimal, default 0) and `remote_area_label` (String|nil); `estimate_cny_for`/`order_estimate_cny` include the surcharge per parcel.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/shipping_cost_calculator_spec.rb — add a describe block.
# Reuse the file's existing GB/AU helpers; this shows the minimal setup.
describe "remote-area surcharge" do
  let(:company) { create(:company) }
  let(:store) do
    create(:shopify_store, company: company, user: create(:user),
           currency: "USD", cost_fx_rate: 7.0, default_service_type: "with_battery")
  end
  let(:customer) { create(:customer, shopify_store: store) }

  def gb_order(zip:, grams: 1000)
    o = create(:order, customer: customer, shopify_store: store,
               ordered_at: Time.utc(2026, 6, 15, 12),
               shopify_data: { "shipping_address" => { "country_code" => "GB", "zip" => zip } })
    variant = create(:product_variant, product: create(:product, shopify_store: store), weight_grams: grams)
    create(:order_line_item, order: o, product_variant: variant, quantity: 1)
    o
  end

  before do
    v = create(:shipping_rate_card_version, company: company, country_code: "GB",
               service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
    create(:shipping_rate_card_rate, version: v, zone: nil, weight_min_kg: 0, weight_max_kg: 5,
           per_kg_rate_cny: 50, flat_fee_cny: 30) # base 1kg: 50*1+30 = 80 (+¥2 op = 82)

    rav = create(:shipping_remote_area_version, company: company, country_code: "GB",
                 effective_from: Date.new(2026, 6, 1))
    create(:shipping_remote_area_rule, version: rav, postal_start: "IV00", postal_end: "IV99",
           surcharge_cny: 17, area_label: "area 2")
  end

  it "adds the surcharge (per parcel) to a matching postcode's estimate" do
    basis = ShippingCostCalculator.basis(gb_order(zip: "IV1 1AA"))
    # 50*1 + 30 flat + 2 op + 17 remote = 99
    expect(basis.order_estimate_cny).to eq(99)
    expect(basis.remote_surcharge_cny).to eq(17)
    expect(basis.remote_area_label).to eq("area 2")
  end

  it "adds nothing for a non-remote postcode" do
    basis = ShippingCostCalculator.basis(gb_order(zip: "M1 1AA"))
    expect(basis.order_estimate_cny).to eq(82) # 80 base + 2 op, no remote
    expect(basis.remote_surcharge_cny).to eq(0)
  end

  it "charges the surcharge once per parcel on an over-max split" do
    basis = ShippingCostCalculator.basis(gb_order(zip: "IV1 1AA", grams: 5500)) # 5.5kg -> 5 + 0.5 = 2 parcels
    # base(5kg: 250+30+2=282) + base(0.5kg: 25+30+2=57) + 17*2 remote = 373
    expect(basis.order_estimate_cny).to eq(373)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/services/shipping_cost_calculator_spec.rb -e "remote-area surcharge"`
Expected: FAIL (`remote_surcharge_cny` undefined; estimate lacks +17).

- [ ] **Step 3: Implement**

In `class Basis`: add `remote_surcharge_cny` / `remote_area_label` (defaulting to 0/nil) and thread the surcharge through `estimate_cny_for`.

```ruby
class Basis
  attr_reader :version, :zone, :zoned, :order_weight_kg, :fx_rate, :rates,
              :remote_surcharge_cny, :remote_area_label

  def initialize(version:, zone:, zoned:, order_weight_kg:, fx_rate:,
                 remote_surcharge_cny: BigDecimal("0"), remote_area_label: nil)
    @version = version
    @zone = zone
    @zoned = zoned
    @order_weight_kg = order_weight_kg
    @fx_rate = fx_rate
    @rates = version.rates.where(zone: zone)
    @remote_surcharge_cny = remote_surcharge_cny || BigDecimal("0")
    @remote_area_label = remote_area_label
  end

  def estimate_cny_for(weight_kg)
    return nil unless weight_kg && weight_kg.positive?
    ShippingCostCalculator.cost_cny_for(rates, weight_kg, @remote_surcharge_cny)
  end
  # order_estimate_cny / order_estimate / display_band unchanged (they call estimate_cny_for)
end
```

Thread the surcharge through `cost_cny_for` (per parcel):

```ruby
def self.cost_cny_for(scope, weight_kg, remote_surcharge_cny = BigDecimal("0"))
  weight = BigDecimal(weight_kg.to_s)
  surcharge = remote_surcharge_cny || BigDecimal("0")

  rate = scope.for_weight(weight).first
  return parcel_cost(rate, weight) + surcharge if rate # single parcel

  bands = scope.to_a
  max = bands.map(&:weight_max_kg).max
  return nil unless max && weight > max
  full_band = band_for(bands, max)
  return nil unless full_band

  full_count = (weight / max).floor
  remainder  = weight - (full_count * max)
  parcels    = full_count
  cost = parcel_cost(full_band, max) * full_count
  if remainder.positive?
    rem_band = band_for(bands, remainder)
    return nil unless rem_band
    cost += parcel_cost(rem_band, remainder)
    parcels += 1
  end
  cost + (surcharge * parcels)
end
```

Resolve the surcharge in `resolve` and pass it to `Basis`:

```ruby
def resolve
  # ... unchanged guards through `zone` ...
  return Resolution.new(reason: :unmatched_zone) if zone == :unmatched

  surcharge_rule = remote_area_rule(country)
  Resolution.new(basis: Basis.new(
    version: version,
    zone: zone,
    zoned: !zone.nil?,
    order_weight_kg: weight_kg,
    fx_rate: @store.cost_fx_rate,
    remote_surcharge_cny: surcharge_rule&.surcharge_cny || BigDecimal("0"),
    remote_area_label: surcharge_rule&.area_label
  ))
end

private

# The remote-area rule matching this order's destination postcode on its order
# date, or nil. Uses the SAME shipping-then-billing postcode + normalizer the
# zone resolution uses, so a surcharge is only added where the postcode maps to
# a remote area for the order's date.
def remote_area_rule(country)
  key = PostalNormalizer.normalize(country, postal_from_order)
  return nil unless key
  version = ShippingRemoteAreaVersion.lookup(
    company: @store.company, country: country, on_date: @order.ordered_at.to_date
  )
  version&.surcharge_for(key)
end
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/services/shipping_cost_calculator_spec.rb`
Expected: PASS (new block + all existing; existing non-GB estimates unchanged — surcharge 0).

- [ ] **Step 5: Commit**

```bash
git add app/services/shipping_cost_calculator.rb spec/services/shipping_cost_calculator_spec.rb
git commit -m "feat(shipping): add per-parcel remote-area surcharge to the estimate"
```

---

### Task 4: Show the surcharge in the /parcels estimate-basis line

**Files:**
- Modify: `app/views/parcels/index.html.erb` (estimate-basis line, near the `parcels.basis.formula` chip)
- Modify: `config/locales/en.yml`, `zh-CN.yml`, `zh-TW.yml`
- Test: `spec/requests/parcels_spec.rb`

**Interfaces:**
- Consumes: `result.basis.remote_surcharge_cny`, `result.basis.remote_area_label`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/requests/parcels_spec.rb — inside the est_store describe (adapt to that block's helpers).
# Assumes a GB order priced with a matching remote rule renders the chip.
it "shows a remote-area surcharge chip in the basis line when the postcode is remote" do
  # Build a GB rate card + remote rule for est_store's company, an order to IV1, and a parcel.
  # (Use the block's existing priced-order helper style; country GB, zip "IV1 1AA".)
  # ...
  get parcels_path
  expect(response.body).to include(I18n.t("parcels.basis.remote_surcharge", amount: "¥17.00", area: "area 2"))
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/requests/parcels_spec.rb -e "remote-area surcharge chip"`
Expected: FAIL (chip/key absent).

- [ ] **Step 3: Implement**

Add i18n (all three locales), e.g. en:
```yaml
    basis:
      # ...
      remote_surcharge: "+ %{amount} 偏遠費 (%{area})"   # zh-CN/zh-TW: 偏遠費/偏遠費; en: "+ %{amount} remote (%{area})"
```

In the basis line, after the formula chip, before the `= total` span:
```erb
<% if result.basis.remote_surcharge_cny && result.basis.remote_surcharge_cny.positive? %>
  <span class="px-2 py-1 rounded bg-amber-50 text-amber-700 text-[11px]">
    <%= t("parcels.basis.remote_surcharge", amount: cny(result.basis.remote_surcharge_cny), area: result.basis.remote_area_label) %>
  </span>
<% end %>
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/requests/parcels_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/views/parcels/index.html.erb config/locales/*.yml spec/requests/parcels_spec.rb
git commit -m "feat(shipping): show remote-area surcharge in the /parcels estimate basis"
```

---

### Task 5: Batch-paste importer service

**Files:**
- Create: `app/services/remote_area_rule_importer.rb`
- Test: `spec/services/remote_area_rule_importer_spec.rb`

**Interfaces:**
- Produces: `RemoteAreaRuleImporter.new(version:, text:).call -> { count:, errors: [] }`. Replaces the version's rules on success. Line format `code, area, price` (tab OR comma). Country for normalization is `version.country_code`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/remote_area_rule_importer_spec.rb
require "rails_helper"
RSpec.describe RemoteAreaRuleImporter do
  let(:version) { create(:shipping_remote_area_version, country_code: "GB") }

  it "imports tab- and comma-separated per-code lines, replacing existing rules" do
    create(:shipping_remote_area_rule, version: version) # pre-existing, must be replaced
    text = "AB35\tarea 3\t10\nBT1, area 3, 10\nIV\tarea 2\t17\n"
    result = described_class.new(version: version, text: text).call
    expect(result[:errors]).to be_empty
    expect(result[:count]).to eq(3)
    version.reload
    expect(version.rules.count).to eq(3)
    expect(version.surcharge_for("AB35").surcharge_cny).to eq(10)
    expect(version.surcharge_for("IV63").surcharge_cny).to eq(17) # bare-letter area covers IV63
    expect(version.surcharge_for("BT01").area_label).to eq("area 3")
  end

  it "reports a line error and writes nothing when a token is malformed" do
    text = "AB35, area 3, 10\n@@@, area 2, 17\n"
    result = described_class.new(version: version, text: text).call
    expect(result[:count]).to eq(0)
    expect(result[:errors].first).to match(/Line 2/)
    expect(version.rules.count).to eq(0)
  end

  it "reports an error for a non-numeric price" do
    result = described_class.new(version: version, text: "AB35, area 3, xx").call
    expect(result[:errors]).not_to be_empty
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/services/remote_area_rule_importer_spec.rb`
Expected: FAIL (class undefined).

- [ ] **Step 3: Implement** (mirrors `PostalZoneImporter`)

```ruby
# app/services/remote_area_rule_importer.rb
class RemoteAreaRuleImporter
  def initialize(version:, text:)
    @version = version
    @country = version.country_code
    @text = text.to_s
  end

  def call
    unless PostalNormalizer::SUPPORTED_COUNTRIES.include?(@country)
      return { count: 0, errors: [ "Unsupported country: #{@country}" ] }
    end
    rows, errors = parse
    return { count: 0, errors: errors } if errors.any?

    ts = Time.current
    ShippingRemoteAreaRule.transaction do
      @version.rules.delete_all
      ShippingRemoteAreaRule.insert_all!(
        rows.map { |r| r.merge(version_id: @version.id, created_at: ts, updated_at: ts) }
      ) if rows.any?
    end
    { count: rows.size, errors: [] }
  end

  private

  # Each line: "<code><TAB|,><area><TAB|,><price>". Returns [rows, errors] where
  # rows = [{postal_start:, postal_end:, surcharge_cny:, area_label:}, ...].
  def parse
    rows = []
    errors = []
    @text.each_line.with_index(1) do |line, n|
      line = line.strip
      next if line.empty?
      parsed = parse_line(line)
      parsed.is_a?(String) ? errors << "Line #{n}: #{parsed}" : rows.concat(parsed)
    end
    errors << "No valid rows found" if rows.empty? && errors.empty?
    [ rows, errors ]
  end

  def parse_line(line)
    parts = line.split(/[\t,]/).map(&:strip)
    return "expected 'code, area, price'" if parts.size < 3
    code, area, price = parts[0], parts[1], parts[2]
    range = PostalNormalizer.range_for(@country, code)
    return "bad postcode '#{code}'" unless range
    amount = BigDecimal(price, exception: false) rescue nil
    return "bad price '#{price}'" if amount.nil? || amount.negative?
    [ { postal_start: range[0], postal_end: range[1], surcharge_cny: amount, area_label: area.presence } ]
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/services/remote_area_rule_importer_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/remote_area_rule_importer.rb spec/services/remote_area_rule_importer_spec.rb
git commit -m "feat(shipping): add remote-area rule batch importer"
```

---

### Task 6: Config UI (versions + rules + import), routes, nav

**Files:**
- Create: `app/controllers/shipping_remote_area_versions_controller.rb`
- Create: `app/controllers/shipping_remote_area_rules_controller.rb`
- Create: `app/views/shipping_remote_area_versions/index.html.erb` (+ any partials)
- Modify: `config/routes.rb`, `app/views/shared/_sidebar.html.erb`, `config/locales/*.yml`
- Test: `spec/requests/shipping_remote_area_versions_spec.rb`, `spec/system/shipping_remote_area_rules_spec.rb`

**Interfaces:**
- Consumes: `RemoteAreaRuleImporter`, the two models. Mirrors `ShippingRateCardVersionsController` (owner-only writes via `require_owner!`; index visible to page-permission holders).

- [ ] **Step 1: Add routes**

```ruby
# config/routes.rb — beside the shipping_rate_card_versions block
resources :shipping_remote_area_versions, only: [ :index, :create, :update, :destroy ] do
  resources :rules, only: [ :create, :destroy ], controller: "shipping_remote_area_rules" do
    post :import, on: :collection
  end
end
```

- [ ] **Step 2: Write the failing request spec**

```ruby
# spec/requests/shipping_remote_area_versions_spec.rb
require "rails_helper"
RSpec.describe "ShippingRemoteAreaVersions", type: :request do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }
  before { sign_in user }

  it "lists versions (owner)" do
    v = create(:shipping_remote_area_version, company: company, country_code: "GB", name: "UK Remote v1")
    create(:shipping_remote_area_rule, version: v, area_label: "area 2")
    get shipping_remote_area_versions_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("UK Remote v1")
  end

  it "creates a version" do
    expect {
      post shipping_remote_area_versions_path, params: {
        shipping_remote_area_version: { country_code: "GB", name: "v1", effective_from: "2026-06-01" }
      }
    }.to change(ShippingRemoteAreaVersion, :count).by(1)
  end

  it "batch-imports rules into a version" do
    v = create(:shipping_remote_area_version, company: company, country_code: "GB")
    post import_shipping_remote_area_version_rules_path(v), params: { text: "AB35, area 3, 10\nIV, area 2, 17" }
    expect(v.reload.rules.count).to eq(2)
  end

  it "denies a non-owner member from creating a version" do
    member = create(:user)
    create(:membership, user: member, company: company, role: :member, permissions: [ "shipping" ])
    sign_out user; sign_in member
    post shipping_remote_area_versions_path, params: {
      shipping_remote_area_version: { country_code: "GB", name: "x", effective_from: "2026-06-01" }
    }
    expect(response).to redirect_to(shipping_remote_area_versions_path)
    expect(ShippingRemoteAreaVersion.count).to eq(0)
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `bundle exec rspec spec/requests/shipping_remote_area_versions_spec.rb`
Expected: FAIL (routes/controllers/views missing).

- [ ] **Step 4: Implement controllers** (mirror `ShippingRateCardVersionsController` / `ShippingRateCardRatesController`)

```ruby
# app/controllers/shipping_remote_area_versions_controller.rb
class ShippingRemoteAreaVersionsController < AdminController
  before_action :require_owner!, only: [ :create, :update, :destroy ]
  before_action :set_version, only: [ :update, :destroy ]

  def index
    versions = current_company.shipping_remote_area_versions.includes(:rules)
    @countries = versions.distinct.pluck(:country_code).sort
    versions = versions.where(country_code: params[:country_code]) if params[:country_code].present?
    @selected_country = params[:country_code]
    @versions = versions.order(country_code: :asc, effective_from: :desc)
  end

  def create
    version = current_company.shipping_remote_area_versions.new(version_params)
    if version.save
      redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.version_created")
    else
      redirect_to shipping_remote_area_versions_path, alert: version.errors.full_messages.join(", ")
    end
  end

  def update
    if @version.update(version_params)
      redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.version_updated")
    else
      redirect_to shipping_remote_area_versions_path, alert: @version.errors.full_messages.join(", ")
    end
  end

  def destroy
    @version.destroy
    redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.version_deleted")
  end

  private

  def set_version
    @version = current_company.shipping_remote_area_versions.find(params[:id])
  end

  def version_params
    params.require(:shipping_remote_area_version).permit(:country_code, :name, :effective_from, :effective_to)
  end

  def require_owner!
    redirect_to(shipping_remote_area_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
```

```ruby
# app/controllers/shipping_remote_area_rules_controller.rb
class ShippingRemoteAreaRulesController < AdminController
  before_action :require_owner!
  before_action :set_version

  def create
    rule = @version.rules.new(rule_params)
    if rule.save
      redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.rule_created")
    else
      redirect_to shipping_remote_area_versions_path, alert: rule.errors.full_messages.join(", ")
    end
  end

  def destroy
    @version.rules.find(params[:id]).destroy
    redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.rule_deleted")
  end

  def import
    result = RemoteAreaRuleImporter.new(version: @version, text: params[:text]).call
    if result[:errors].empty?
      redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.import_done", count: result[:count])
    else
      flash[:remote_import_errors] = result[:errors]
      redirect_to shipping_remote_area_versions_path, alert: t("remote_areas.import_errors")
    end
  end

  private

  def set_version
    @version = current_company.shipping_remote_area_versions.find(params[:shipping_remote_area_version_id])
  end

  def rule_params
    params.require(:shipping_remote_area_rule).permit(:postal_start, :postal_end, :surcharge_cny, :area_label)
  end

  def require_owner!
    redirect_to(shipping_remote_area_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
```

- [ ] **Step 5: Implement the index view** (model it on `app/views/shipping_rate_card_versions/index.html.erb`): list each version (country · effective range), a create-version form, per-version a rules table + a "批量导入" textarea posting to `import_shipping_remote_area_version_rules_path(version)` with `name="text"`, and version/rule delete buttons. Show `flash[:remote_import_errors]` if present. Add `nav`/page links.

Add i18n `remote_areas.*` (title, version_created/updated/deleted, rule_created/deleted, import_done, import_errors, import_hint, column headers) and `nav.shipping_remote_areas` in all three locales, and a sidebar link under the Shipping submenu (mirror the `shipping_zone_postal_rules` link in `app/views/shared/_sidebar.html.erb`).

- [ ] **Step 6: Run request spec + a system spec**

```ruby
# spec/system/shipping_remote_area_rules_spec.rb — Turbo UI: paste import shows the new rules.
require "rails_helper"
RSpec.describe "Remote area rules", type: :system do
  it "batch-imports pasted rules and shows them" do
    user = create(:user)
    login_as(user) # per the suite's auth helper
    v = create(:shipping_remote_area_version, company: user.companies.first, country_code: "GB", name: "UK v1")
    visit shipping_remote_area_versions_path
    fill_in "text_#{v.id}", with: "AB35, area 3, 10\nIV, area 2, 17" # textarea id per the view
    click_button "import_#{v.id}" # submit button per the view
    expect(page).to have_content("area 2")
  end
end
```

Run: `bundle exec rspec spec/requests/shipping_remote_area_versions_spec.rb spec/system/shipping_remote_area_rules_spec.rb`
Expected: PASS. (Adjust the textarea/button identifiers in the view + spec to match.)

- [ ] **Step 7: Full suite + commit**

Run: `bundle exec rspec && bin/rubocop && bin/brakeman --no-pager`
Expected: green, ≥95% coverage, no offenses/warnings.

```bash
git add app/controllers/shipping_remote_area_versions_controller.rb app/controllers/shipping_remote_area_rules_controller.rb app/views/shipping_remote_area_versions config/routes.rb app/views/shared/_sidebar.html.erb config/locales/*.yml spec/requests/shipping_remote_area_versions_spec.rb spec/system/shipping_remote_area_rules_spec.rb
git commit -m "feat(shipping): remote-area surcharge config page with batch import"
```

---

## Self-Review

**Spec coverage:** §3 model → Task 2; §4 GB normalization → Task 1; §5 estimate integration → Task 3; §6 display → Task 4; §7 UI + import → Tasks 5–6; §8 reconciliation → no code (uses existing decomposition, verified by Task 3/4 numbers); §9 testing → each task's tests + mutation notes below.

**Mutation checks (call out during review):** (a) drop `+ surcharge` in `cost_cny_for` → Task 3 surcharge specs fail; (b) change `surcharge_for` ordering to `asc` → Task 2 "most specific" spec fails; (c) skip `@version.rules.delete_all` in the importer → Task 5 "replacing existing rules" spec fails.

**Type consistency:** `remote_surcharge_cny`/`remote_area_label` names identical across Basis (Task 3) and the view (Task 4); `surcharge_for(key)` returns a rule (Task 2) consumed by Task 3; importer returns `{count:, errors:}` (Task 5) consumed by Task 6 exactly like `PostalZoneImporter`/`RateCardRateImporter`.

**Note for executor:** Tasks 4 and 6 reference view-specific identifiers (textarea/button ids, the est_store request-spec helpers). The implementer must read the neighbouring existing view (`shipping_rate_card_versions/index.html.erb`) and the `parcels_spec.rb` est_store block first and match their conventions; the plan pins behavior, not exact DOM ids.
