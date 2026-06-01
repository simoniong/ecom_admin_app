# Zone-Based Shipping Rates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add postal-zone-based shipping pricing for carrier-zoned countries (AU, CA) while keeping flat country-level pricing unchanged for the rest.

**Architecture:** Add a nullable `zone` to `shipping_rate_card_rates` (NULL = flat, unchanged) and a new `shipping_zone_postal_rules` table mapping normalized postal-code ranges → zone, one current set per country. A `PostalNormalizer` PORO produces fixed-width lexicographically-sortable keys, used both at import (rule endpoints) and lookup (order postal). `ShippingCostCalculator` resolves the order's zone before the weight-band rate lookup. Two bulk-import services (postal map, version rates) parse pasted text and replace rows transactionally.

**Tech Stack:** Rails 8.1, PostgreSQL (UUID PKs), Hotwire, RSpec + FactoryBot.

**Spec:** `docs/superpowers/specs/2026-06-01-zone-based-shipping-rates-design.md`

**Conventions (from the existing shipping feature — follow exactly):**
- `bin/rails`/`bundle`/`rspec` need ruby on PATH: `export PATH="/home/simon/.rubies/ruby-3.4.7/bin:$PATH"`.
- SimpleCov fails a single-file run with exit 2 (global 95% gate) — EXPECTED; judge by `N examples, M failures`.
- New tables: `id: :uuid, default: -> { "gen_random_uuid()" }`; FK columns `t.uuid`; explicit `add_foreign_key`; named indexes.
- Path helpers MUST use keyword args (`_path(id: x.id)`, `_path(shipping_rate_card_version_id: v.id)`) — the routes are under `scope "(:locale)"`.
- Owner-gate inline: mutations gated by `current_membership&.owner?`; page-view via `AdminController::PERMISSION_KEY_MAP`.
- Branch: `feature/zone-based-shipping-rates` (already created off staging; the spec is committed there). Do NOT switch branches.
- Money: CNY ÷ `cost_fx_rate` → store currency.

---

## File Structure

**Migrations (new):**
- `db/migrate/20260601120001_add_zone_to_shipping_rate_card_rates.rb`
- `db/migrate/20260601120002_create_shipping_zone_postal_rules.rb`

**Services (new):** `app/services/postal_normalizer.rb`, `app/services/postal_zone_importer.rb`, `app/services/rate_card_rate_importer.rb`
**Services (modified):** `app/services/shipping_cost_calculator.rb`

**Models (new):** `app/models/shipping_zone_postal_rule.rb`
**Models (modified):** `app/models/company.rb` (assoc)

**Controllers (new):** `app/controllers/shipping_zone_postal_rules_controller.rb`
**Controllers (modified):** `app/controllers/shipping_rate_card_rates_controller.rb` (add `import`), `app/controllers/admin_controller.rb` (PERMISSION_KEY_MAP)

**Views (new):** `app/views/shipping_zone_postal_rules/index.html.erb`
**Views (modified):** `app/views/shipping_rate_card_versions/_version.html.erb` (+ `_rate.html.erb`, rate bulk-import form), `app/views/shared/_sidebar.html.erb`

**Config (modified):** `config/routes.rb`, `config/locales/{en,zh-CN,zh-TW}.yml`
**Factories (new):** `spec/factories/shipping_zone_postal_rules.rb`

---

## Task 1: Migrations (zone column + postal-rules table)

**Files:**
- Create: `db/migrate/20260601120001_add_zone_to_shipping_rate_card_rates.rb`
- Create: `db/migrate/20260601120002_create_shipping_zone_postal_rules.rb`

- [ ] **Step 1: Write the zone-column migration**

```ruby
class AddZoneToShippingRateCardRates < ActiveRecord::Migration[8.1]
  def change
    add_column :shipping_rate_card_rates, :zone, :string
    add_index  :shipping_rate_card_rates, [ :version_id, :zone ]
  end
end
```

- [ ] **Step 2: Write the postal-rules-table migration**

```ruby
class CreateShippingZonePostalRules < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_zone_postal_rules, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid   :company_id, null: false
      t.string :country_code, null: false
      t.string :zone, null: false
      t.string :postal_start, null: false
      t.string :postal_end, null: false
      t.timestamps
    end
    add_index :shipping_zone_postal_rules, [ :company_id, :country_code, :postal_start ],
              name: "idx_zone_postal_lookup"
    add_foreign_key :shipping_zone_postal_rules, :companies
  end
end
```

- [ ] **Step 3: Migrate**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: both run; `db/schema.rb` shows `zone` on `shipping_rate_card_rates` and the new `shipping_zone_postal_rules` table.

- [ ] **Step 4: Verify schema**

Run: `grep -E "shipping_zone_postal_rules|t.string \"zone\"|idx_zone_postal_lookup" db/schema.rb`
Expected: all present.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260601120001_add_zone_to_shipping_rate_card_rates.rb \
        db/migrate/20260601120002_create_shipping_zone_postal_rules.rb db/schema.rb
git commit -m "feat: add zone column + shipping_zone_postal_rules table"
```

---

## Task 2: `PostalNormalizer` PORO

**Files:**
- Create: `app/services/postal_normalizer.rb`
- Test: `spec/services/postal_normalizer_spec.rb`

- [ ] **Step 1: Write the failing spec**

`spec/services/postal_normalizer_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe PostalNormalizer do
  describe ".normalize (lookup key)" do
    it "zero-pads AU to 4 digits" do
      expect(described_class.normalize("AU", "200")).to eq("0200")
      expect(described_class.normalize("AU", "2158")).to eq("2158")
      expect(described_class.normalize("AU", " 2075 ")).to eq("2075")
    end

    it "rejects bad AU postals" do
      expect(described_class.normalize("AU", "12345")).to be_nil
      expect(described_class.normalize("AU", "AB")).to be_nil
      expect(described_class.normalize("AU", "")).to be_nil
    end

    it "normalizes CA to 6 chars, padding FSA-only with 000" do
      expect(described_class.normalize("CA", "g0a 4v0")).to eq("G0A4V0")
      expect(described_class.normalize("CA", "G0A")).to eq("G0A000")
    end

    it "rejects bad CA postals" do
      expect(described_class.normalize("CA", "G0A4")).to be_nil
      expect(described_class.normalize("CA", "")).to be_nil
    end

    it "returns nil for countries with no postal map" do
      expect(described_class.normalize("US", "90210")).to be_nil
    end
  end

  describe ".range_for (rule endpoints)" do
    it "expands AU ranges and singles" do
      expect(described_class.range_for("AU", "1000-1935")).to eq(%w[1000 1935])
      expect(described_class.range_for("AU", "2158")).to eq(%w[2158 2158])
      expect(described_class.range_for("AU", "200-299")).to eq(%w[0200 0299])
    end

    it "rejects inverted / bad AU ranges" do
      expect(described_class.range_for("AU", "1935-1000")).to be_nil
      expect(described_class.range_for("AU", "abc")).to be_nil
    end

    it "expands CA FSA (3) and sub-range (6) tokens to the FSA's ZZZ ceiling" do
      expect(described_class.range_for("CA", "V9N")).to eq(%w[V9N000 V9NZZZ])
      expect(described_class.range_for("CA", "G0A4V0")).to eq(%w[G0A4V0 G0AZZZ])
    end

    it "rejects bad CA tokens" do
      expect(described_class.range_for("CA", "G0A4")).to be_nil
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/postal_normalizer_spec.rb`
Expected: FAIL — `uninitialized constant PostalNormalizer`.

- [ ] **Step 3: Write the PORO**

`app/services/postal_normalizer.rb`:

```ruby
class PostalNormalizer
  # Normalize an order's raw postal into a fixed-width lookup key, or nil.
  def self.normalize(country, raw)
    return nil if raw.blank?
    case country
    when "AU" then normalize_au(raw)
    when "CA" then normalize_ca(raw)
    end
  end

  # Expand one import token into [start_key, end_key], or nil if malformed.
  def self.range_for(country, token)
    case country
    when "AU" then range_au(token)
    when "CA" then range_ca(token)
    end
  end

  def self.normalize_au(raw)
    s = raw.to_s.gsub(/\s/, "")
    return nil unless s.match?(/\A\d{1,4}\z/)
    s.rjust(4, "0")
  end

  def self.range_au(token)
    if token.to_s.include?("-")
      a, b = token.to_s.split("-", 2).map { |x| normalize_au(x) }
      (a && b && b >= a) ? [ a, b ] : nil
    else
      v = normalize_au(token)
      v && [ v, v ]
    end
  end

  def self.normalize_ca(raw)
    s = raw.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    case s.length
    when 6 then s
    when 3 then "#{s}000"
    end
  end

  def self.range_ca(token)
    s = token.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    case s.length
    when 3 then [ "#{s}000", "#{s}ZZZ" ]
    when 6 then [ s, "#{s[0, 3]}ZZZ" ]
    end
  end

  private_class_method :normalize_au, :range_au, :normalize_ca, :range_ca
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/postal_normalizer_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/postal_normalizer.rb spec/services/postal_normalizer_spec.rb
git commit -m "feat: add PostalNormalizer (AU/CA postal key normalization)"
```

---

## Task 3: `ShippingZonePostalRule` model

**Files:**
- Create: `app/models/shipping_zone_postal_rule.rb`
- Create: `spec/factories/shipping_zone_postal_rules.rb`
- Modify: `app/models/company.rb`
- Test: `spec/models/shipping_zone_postal_rule_spec.rb`

- [ ] **Step 1: Write the factory**

`spec/factories/shipping_zone_postal_rules.rb`:

```ruby
FactoryBot.define do
  factory :shipping_zone_postal_rule do
    company
    country_code { "AU" }
    zone { "1" }
    postal_start { "2000" }
    postal_end { "2079" }
  end
end
```

- [ ] **Step 2: Write the failing spec**

`spec/models/shipping_zone_postal_rule_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ShippingZonePostalRule, type: :model do
  let(:company) { create(:company) }

  describe "validations" do
    it "requires the key fields" do
      r = described_class.new(company: company)
      expect(r).not_to be_valid
      expect(r.errors.attribute_names).to include(:country_code, :zone, :postal_start, :postal_end)
    end

    it "rejects postal_end before postal_start" do
      r = build(:shipping_zone_postal_rule, company: company, postal_start: "2000", postal_end: "1000")
      expect(r).not_to be_valid
      expect(r.errors[:postal_end]).to be_present
    end
  end

  describe ".zone_for / .country_zoned?" do
    before do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1", postal_start: "2000", postal_end: "2079")
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "2", postal_start: "2080", postal_end: "2084")
      # CA: whole-FSA rule (zone 2) overlapped by a sub-range rule (zone 1)
      create(:shipping_zone_postal_rule, company: company, country_code: "CA", zone: "2", postal_start: "G0A000", postal_end: "G0AZZZ")
      create(:shipping_zone_postal_rule, company: company, country_code: "CA", zone: "1", postal_start: "G0A4V0", postal_end: "G0AZZZ")
    end

    it "matches AU numeric ranges" do
      expect(described_class.zone_for(company: company, country: "AU", key: "2075")).to eq("1")
      expect(described_class.zone_for(company: company, country: "AU", key: "2082")).to eq("2")
    end

    it "returns nil when AU key is outside every range" do
      expect(described_class.zone_for(company: company, country: "AU", key: "9999")).to be_nil
    end

    it "picks the most specific CA rule (greatest postal_start) on overlap" do
      expect(described_class.zone_for(company: company, country: "CA", key: "G0A5A0")).to eq("1")  # >= G0A4V0
      expect(described_class.zone_for(company: company, country: "CA", key: "G0A1A0")).to eq("2")  # below sub-range
    end

    it "is scoped by company" do
      other = create(:company)
      expect(described_class.zone_for(company: other, country: "AU", key: "2075")).to be_nil
    end

    it "reports country_zoned?" do
      expect(described_class.country_zoned?(company: company, country: "AU")).to be(true)
      expect(described_class.country_zoned?(company: company, country: "US")).to be(false)
    end
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bundle exec rspec spec/models/shipping_zone_postal_rule_spec.rb`
Expected: FAIL — `uninitialized constant ShippingZonePostalRule`.

- [ ] **Step 4: Write the model**

`app/models/shipping_zone_postal_rule.rb`:

```ruby
class ShippingZonePostalRule < ApplicationRecord
  belongs_to :company

  validates :country_code, :zone, :postal_start, :postal_end, presence: true
  validate  :end_not_before_start

  scope :match_for, ->(country:, key:) {
    where(country_code: country)
      .where("postal_start <= :k AND postal_end >= :k", k: key)
      .order(postal_start: :desc)
  }

  def self.zone_for(company:, country:, key:)
    where(company_id: company.id).match_for(country: country, key: key).first&.zone
  end

  def self.country_zoned?(company:, country:)
    where(company_id: company.id, country_code: country).exists?
  end

  private

  def end_not_before_start
    return unless postal_start && postal_end
    errors.add(:postal_end, "must be on or after postal_start") if postal_end < postal_start
  end
end
```

- [ ] **Step 5: Add the Company association**

In `app/models/company.rb`, with the other `has_many` lines:

```ruby
  has_many :shipping_zone_postal_rules, dependent: :destroy
```

- [ ] **Step 6: Run to verify it passes**

Run: `bundle exec rspec spec/models/shipping_zone_postal_rule_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/models/shipping_zone_postal_rule.rb spec/factories/shipping_zone_postal_rules.rb \
        spec/models/shipping_zone_postal_rule_spec.rb app/models/company.rb
git commit -m "feat: add ShippingZonePostalRule model with zone_for lookup"
```

---

## Task 4: Calculator zone resolution

**Files:**
- Modify: `app/services/shipping_cost_calculator.rb`
- Test: `spec/services/shipping_cost_calculator_spec.rb` (extend)

- [ ] **Step 1: Write the failing spec additions**

Add to `spec/services/shipping_cost_calculator_spec.rb` (a new `describe` block inside the top-level describe). It reuses the file's existing `company`/`store`/`customer` lets and helpers; mirror their style (the store has `cost_fx_rate: 7.0, default_service_type: "with_battery"`):

```ruby
  describe "zone-based countries" do
    # AU order to a given postcode, 0.3 kg.
    def au_order(zip:, ordered_on: Date.new(2026, 4, 15))
      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(ordered_on.year, ordered_on.month, ordered_on.day, 12),
                     shopify_data: { "shipping_address" => { "country_code" => "AU", "zip" => zip } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 300)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      order
    end

    before do
      # postal map: zone 1 = 2000-2079, zone 2 = 2080-2084
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1", postal_start: "2000", postal_end: "2079")
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "2", postal_start: "2080", postal_end: "2084")
      # version + zoned rates for AU/with_battery covering 0.3 kg
      version = create(:shipping_rate_card_version, company: company, country_code: "AU",
                       service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: version, zone: "1", weight_min_kg: 0.201, weight_max_kg: 0.45, per_kg_rate_cny: 92.0, flat_fee_cny: 23.0)
      create(:shipping_rate_card_rate, version: version, zone: "2", weight_min_kg: 0.201, weight_max_kg: 0.45, per_kg_rate_cny: 100.0, flat_fee_cny: 30.0)
    end

    it "uses the zone-1 rate for a zone-1 postcode" do
      # 0.3*92 + 23 = 50.6 / 7.0 = 7.23
      expect(ShippingCostCalculator.estimate(au_order(zip: "2075"))).to eq(7.23)
    end

    it "uses the zone-2 rate for a zone-2 postcode" do
      # 0.3*100 + 30 = 60 / 7.0 = 8.57
      expect(ShippingCostCalculator.estimate(au_order(zip: "2082"))).to eq(8.57)
    end

    it "returns nil when the postcode matches no zone" do
      expect(ShippingCostCalculator.estimate(au_order(zip: "9999"))).to be_nil
    end

    it "returns nil when the order has no postcode" do
      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     shopify_data: { "shipping_address" => { "country_code" => "AU" } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 300)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      expect(ShippingCostCalculator.estimate(order)).to be_nil
    end

    it "returns nil when the version has no rate for the resolved zone" do
      # zone-3 postcode mapped, but no zone-3 rate exists
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "3", postal_start: "3000", postal_end: "3062")
      expect(ShippingCostCalculator.estimate(au_order(zip: "3050"))).to be_nil
    end
  end
```

> NOTE on existing flat examples: the file's existing examples create rates via `build_version_with_band` / the rate factory WITHOUT a zone (zone defaults to NULL). After this task, the flat path looks up `where(zone: nil)`, which matches those NULL-zone rates — so the existing examples must still pass unchanged. Confirm in Step 4.

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/shipping_cost_calculator_spec.rb -e "zone-based"`
Expected: FAIL — the calculator ignores zones (zone-1 and zone-2 both currently match the first `for_weight` rate, and the no-postcode/no-match cases don't return nil).

- [ ] **Step 3: Modify the calculator**

In `app/services/shipping_cost_calculator.rb`, replace the rate-lookup section of `call`. The current code is:

```ruby
    return nil unless version

    rate = version.rates.for_weight(weight_kg).first
    return nil unless rate
```

Replace with:

```ruby
    return nil unless version

    zone = resolve_zone(country)
    return nil if zone == :unmatched

    rate = version.rates.where(zone: (zone == :flat ? nil : zone)).for_weight(weight_kg).first
    return nil unless rate
```

Add two private methods (next to `country_code_from_order`):

```ruby
  def resolve_zone(country)
    return :flat unless ShippingZonePostalRule.country_zoned?(company: @store.company, country: country)
    key = PostalNormalizer.normalize(country, postal_from_order)
    return :unmatched unless key
    ShippingZonePostalRule.zone_for(company: @store.company, country: country, key: key) || :unmatched
  end

  def postal_from_order
    @order.shopify_data&.dig("shipping_address", "zip") ||
      @order.shopify_data&.dig("billing_address", "zip")
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/shipping_cost_calculator_spec.rb`
Expected: PASS — the new zone examples AND every pre-existing flat example (flat path uses `where(zone: nil)`).

- [ ] **Step 5: Commit**

```bash
git add app/services/shipping_cost_calculator.rb spec/services/shipping_cost_calculator_spec.rb
git commit -m "feat: resolve postal zone in ShippingCostCalculator"
```

---

## Task 5: `PostalZoneImporter` service

**Files:**
- Create: `app/services/postal_zone_importer.rb`
- Test: `spec/services/postal_zone_importer_spec.rb`

Parses pasted text for one country and, only if every line is valid, replaces that country's rows transactionally. Returns `{ count:, errors: }` (errors = array of human-readable line messages; empty = success).

- [ ] **Step 1: Write the failing spec**

`spec/services/postal_zone_importer_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe PostalZoneImporter do
  let(:company) { create(:company) }

  describe "AU import" do
    let(:text) { "1: 1000-1935, 2000-2079, 2158\n2: 2080-2084, 200-299" }

    it "replaces the country's rows and reports the count" do
      result = described_class.new(company: company, country: "AU", text: text).call
      expect(result[:errors]).to be_empty
      expect(result[:count]).to eq(5)
      rules = company.shipping_zone_postal_rules.where(country_code: "AU")
      expect(rules.count).to eq(5)
      expect(rules.find_by(postal_start: "0200")).to have_attributes(postal_end: "0299", zone: "2")
      expect(ShippingZonePostalRule.zone_for(company: company, country: "AU", key: "2075")).to eq("1")
    end

    it "wipes prior AU rows on re-import (replace semantics)" do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "9", postal_start: "5000", postal_end: "5001")
      described_class.new(company: company, country: "AU", text: text).call
      expect(company.shipping_zone_postal_rules.where(country_code: "AU", zone: "9")).to be_empty
    end

    it "aborts and writes nothing when a line is malformed" do
      bad = "1: 1000-1935\n2: oops-bad"
      result = described_class.new(company: company, country: "AU", text: bad).call
      expect(result[:errors]).not_to be_empty
      expect(company.shipping_zone_postal_rules.where(country_code: "AU").count).to eq(0)
    end

    it "does not touch other countries" do
      create(:shipping_zone_postal_rule, company: company, country_code: "CA", zone: "1", postal_start: "G0A000", postal_end: "G0AZZZ")
      described_class.new(company: company, country: "AU", text: text).call
      expect(company.shipping_zone_postal_rules.where(country_code: "CA").count).to eq(1)
    end
  end

  describe "CA import" do
    let(:text) { "G0A4V0,1\nG0B,1\nV9N,2" }

    it "expands FSA (3) and full (6) tokens correctly" do
      result = described_class.new(company: company, country: "CA", text: text).call
      expect(result[:errors]).to be_empty
      expect(result[:count]).to eq(3)
      expect(ShippingZonePostalRule.zone_for(company: company, country: "CA", key: "V9N5A0")).to eq("2")
      expect(ShippingZonePostalRule.zone_for(company: company, country: "CA", key: "G0A5A0")).to eq("1")
    end

    it "aborts on a bad CA token" do
      result = described_class.new(company: company, country: "CA", text: "G0A4V0,1\nXX,2").call
      expect(result[:errors]).not_to be_empty
      expect(company.shipping_zone_postal_rules.where(country_code: "CA").count).to eq(0)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/postal_zone_importer_spec.rb`
Expected: FAIL — `uninitialized constant PostalZoneImporter`.

- [ ] **Step 3: Write the service**

`app/services/postal_zone_importer.rb`:

```ruby
class PostalZoneImporter
  def initialize(company:, country:, text:)
    @company = company
    @country = country
    @text = text.to_s
  end

  def call
    rows, errors = parse
    return { count: 0, errors: errors } if errors.any?

    ShippingZonePostalRule.transaction do
      @company.shipping_zone_postal_rules.where(country_code: @country).delete_all
      ShippingZonePostalRule.insert_all!(rows.map { |r| r.merge(company_id: @company.id, country_code: @country) }) if rows.any?
    end
    { count: rows.size, errors: [] }
  end

  private

  # Returns [rows, errors]. rows = [{zone:, postal_start:, postal_end:}, ...]
  def parse
    rows = []
    errors = []
    @text.each_line.with_index(1) do |line, n|
      line = line.strip
      next if line.empty?
      parsed = (@country == "AU" ? parse_au_line(line) : parse_ca_line(line))
      if parsed.is_a?(String)
        errors << "Line #{n}: #{parsed}"
      else
        rows.concat(parsed)
      end
    end
    errors << "No valid rows found" if rows.empty? && errors.empty?
    [ rows, errors ]
  end

  # "1: 1000-1935, 2000-2079, 2158" -> rows, or an error String
  def parse_au_line(line)
    zone, rest = line.split(":", 2)
    return "expected '<zone>: <ranges>'" if rest.nil? || zone.strip.empty?
    zone = zone.strip
    out = []
    rest.split(",").each do |tok|
      tok = tok.strip
      next if tok.empty?
      range = PostalNormalizer.range_for("AU", tok)
      return "bad postcode/range '#{tok}'" unless range
      out << { zone: zone, postal_start: range[0], postal_end: range[1] }
    end
    out.empty? ? "no ranges" : out
  end

  # "G0A4V0,1" -> rows, or an error String
  def parse_ca_line(line)
    token, zone = line.split(",", 2)
    return "expected '<postal>,<zone>'" if zone.nil? || token.to_s.strip.empty?
    range = PostalNormalizer.range_for("CA", token.strip)
    return "bad postal '#{token.strip}'" unless range
    [ { zone: zone.strip, postal_start: range[0], postal_end: range[1] } ]
  end
end
```

> NOTE: `insert_all!` skips model validations and timestamps. Add `created_at`/`updated_at` so NOT NULL timestamp columns are satisfied: change the `insert_all!` mapping to include `now = Time.current` stamped on each row. Concretely, in `call` compute `ts = Time.current` and map `r.merge(company_id:, country_code:, created_at: ts, updated_at: ts)`. (Rails' `insert_all` does NOT auto-set timestamps.)

- [ ] **Step 4: Apply the timestamp note**

Edit `call` so the insert includes timestamps:

```ruby
  def call
    rows, errors = parse
    return { count: 0, errors: errors } if errors.any?

    ts = Time.current
    ShippingZonePostalRule.transaction do
      @company.shipping_zone_postal_rules.where(country_code: @country).delete_all
      if rows.any?
        ShippingZonePostalRule.insert_all!(
          rows.map { |r| r.merge(company_id: @company.id, country_code: @country, created_at: ts, updated_at: ts) }
        )
      end
    end
    { count: rows.size, errors: [] }
  end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec rspec spec/services/postal_zone_importer_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/postal_zone_importer.rb spec/services/postal_zone_importer_spec.rb
git commit -m "feat: add PostalZoneImporter (bulk paste -> zone rules, replace)"
```

---

## Task 6: `RateCardRateImporter` service

**Files:**
- Create: `app/services/rate_card_rate_importer.rb`
- Test: `spec/services/rate_card_rate_importer_spec.rb`

Parses `zone,min,max,per_kg,flat` lines for one version; if all valid, replaces that version's rates transactionally. Blank zone → NULL (flat). Returns `{ count:, errors: }`.

- [ ] **Step 1: Write the failing spec**

`spec/services/rate_card_rate_importer_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe RateCardRateImporter do
  let(:version) { create(:shipping_rate_card_version) }

  it "replaces the version's rates and sets zones" do
    create(:shipping_rate_card_rate, version: version, zone: nil)  # prior row, should be wiped
    text = "1,0,0.25,27,23\n1,0.251,0.3,27,23\n2,0,0.25,27,31"
    result = described_class.new(version: version, text: text).call
    expect(result[:errors]).to be_empty
    expect(result[:count]).to eq(3)
    expect(version.rates.reload.count).to eq(3)
    expect(version.rates.where(zone: "1").count).to eq(2)
    expect(version.rates.find_by(zone: "2", weight_min_kg: 0)).to have_attributes(per_kg_rate_cny: 27, flat_fee_cny: 31)
  end

  it "treats a blank zone as flat (nil)" do
    described_class.new(version: version, text: ",0,0.25,92,25").call
    expect(version.rates.reload.first.zone).to be_nil
  end

  it "aborts and writes nothing on a bad line (max <= min)" do
    create(:shipping_rate_card_rate, version: version)
    before = version.rates.count
    result = described_class.new(version: version, text: "1,0.3,0.3,27,23").call
    expect(result[:errors]).not_to be_empty
    expect(version.rates.reload.count).to eq(before)  # unchanged
  end

  it "aborts on a non-numeric field" do
    result = described_class.new(version: version, text: "1,0,abc,27,23").call
    expect(result[:errors]).not_to be_empty
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/services/rate_card_rate_importer_spec.rb`
Expected: FAIL — `uninitialized constant RateCardRateImporter`.

- [ ] **Step 3: Write the service**

`app/services/rate_card_rate_importer.rb`:

```ruby
class RateCardRateImporter
  def initialize(version:, text:)
    @version = version
    @text = text.to_s
  end

  def call
    rows, errors = parse
    return { count: 0, errors: errors } if errors.any?

    ShippingRateCardRate.transaction do
      @version.rates.delete_all
      rows.each { |attrs| @version.rates.create!(attrs) }
    end
    { count: rows.size, errors: [] }
  end

  private

  def parse
    rows = []
    errors = []
    @text.each_line.with_index(1) do |line, n|
      line = line.strip
      next if line.empty?
      fields = line.split(",").map(&:strip)
      if fields.size != 5
        errors << "Line #{n}: expected 'zone,min,max,per_kg,flat'"
        next
      end
      zone, min, max, per_kg, flat = fields
      nums = [ min, max, per_kg, flat ].map { |x| Float(x) rescue nil }
      if nums.any?(&:nil?)
        errors << "Line #{n}: non-numeric value"
        next
      end
      min_v, max_v, per_v, flat_v = nums
      if max_v <= min_v
        errors << "Line #{n}: max (#{max_v}) must be > min (#{min_v})"
        next
      end
      rows << {
        zone: zone.presence,
        weight_min_kg: min_v, weight_max_kg: max_v,
        per_kg_rate_cny: per_v, flat_fee_cny: flat_v
      }
    end
    errors << "No valid rows found" if rows.empty? && errors.empty?
    [ rows, errors ]
  end
end
```

> Uses `create!` (not `insert_all`) so the model's numericality/`weight_max_greater_than_min` validations still run as a backstop. The parser already rejects bad lines, so `create!` won't raise in the happy path.

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/services/rate_card_rate_importer_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/rate_card_rate_importer.rb spec/services/rate_card_rate_importer_spec.rb
git commit -m "feat: add RateCardRateImporter (bulk paste -> version rates, replace)"
```

---

## Task 7: Routes, authz, i18n, nav

**Files:**
- Modify: `config/routes.rb`, `app/controllers/admin_controller.rb`, `config/locales/{en,zh-CN,zh-TW}.yml`, `app/views/shared/_sidebar.html.erb`

- [ ] **Step 1: Routes**

In `config/routes.rb`, inside the locale-scoped authenticated block, add a nested `import` to rates and the new postal-rules resource. Change the existing block (lines ~72–75):

```ruby
    resources :shipping_rate_card_versions, only: [ :index, :create, :update, :destroy ] do
      resources :rates, only: [ :create, :update, :destroy ],
                controller: "shipping_rate_card_rates" do
        post :import, on: :collection
      end
    end
    resources :shipping_zone_postal_rules, only: [ :index ] do
      post :import, on: :collection
    end
```

- [ ] **Step 2: Permission map**

In `app/controllers/admin_controller.rb`, add to `PERMISSION_KEY_MAP`:

```ruby
    "shipping_zone_postal_rules" => "shopify_stores",
```

- [ ] **Step 3: en locale**

In `config/locales/en.yml`, add under `shipping_rate_cards:` a `columns.zone` and bulk-import keys, a new top-level `shipping_zone_postal_rules:` block, and a `nav` entry:

```yaml
  # under shipping_rate_cards.columns:
      zone: "Zone"
  # under shipping_rate_cards: (top of the block)
    bulk_import_rates: "Bulk import rates"
    bulk_import_rates_hint: "One line per rate: zone,min_kg,max_kg,¥/kg,¥/pkg (blank zone = flat)"
    bulk_import_done: "Imported %{count} rows"
    bulk_import_errors: "Import failed — fix these lines:"
  # new top-level block (sibling of shipping_rate_cards):
  shipping_zone_postal_rules:
    title: "Postal Zones"
    country: "Country"
    import_label: "Bulk import postal → zone map"
    au_hint: "One line per zone: 1: 1000-1935, 2000-2079, 2158"
    ca_hint: "One line per rule: G0A4V0,1 or G0B,1"
    import_button: "Import (replaces this country's map)"
    imported: "Imported %{count} rules for %{country}"
    errors_title: "Import failed — nothing was saved. Fix these lines:"
    summary_title: "Current map"
    zone_count: "zone %{zone}: %{count} ranges"
    empty: "No postal zones imported yet"
  # under nav:
    shipping_zone_postal_rules: "Postal Zones"
```

- [ ] **Step 4: zh-CN / zh-TW**

Add the same keys with translations.

zh-CN (`config/locales/zh-CN.yml`):
```yaml
  # shipping_rate_cards.columns.zone: "分区"
  # shipping_rate_cards: bulk_import_rates "批量导入费率", bulk_import_rates_hint "每行一条：分区,最小kg,最大kg,¥/kg,¥/件（分区留空=单一费率）", bulk_import_done "已导入 %{count} 行", bulk_import_errors "导入失败——请修正这些行："
  shipping_zone_postal_rules:
    title: "邮编分区"
    country: "国家"
    import_label: "批量导入 邮编→分区 表"
    au_hint: "每个分区一行：1: 1000-1935, 2000-2079, 2158"
    ca_hint: "每条一行：G0A4V0,1 或 G0B,1"
    import_button: "导入（会取代该国的整份表）"
    imported: "已为 %{country} 导入 %{count} 条规则"
    errors_title: "导入失败——未保存任何内容。请修正这些行："
    summary_title: "目前的对应表"
    zone_count: "%{zone}区：%{count} 段"
    empty: "尚未导入任何邮编分区"
  # nav.shipping_zone_postal_rules: "邮编分区"
```

zh-TW (`config/locales/zh-TW.yml`):
```yaml
  # shipping_rate_cards.columns.zone: "分區"
  # shipping_rate_cards: bulk_import_rates "批量匯入費率", bulk_import_rates_hint "每行一筆：分區,最小kg,最大kg,¥/kg,¥/件（分區留空=單一費率）", bulk_import_done "已匯入 %{count} 列", bulk_import_errors "匯入失敗——請修正這些行："
  shipping_zone_postal_rules:
    title: "郵編分區"
    country: "國家"
    import_label: "批量匯入 郵編→分區 表"
    au_hint: "每個分區一行：1: 1000-1935, 2000-2079, 2158"
    ca_hint: "每筆一行：G0A4V0,1 或 G0B,1"
    import_button: "匯入（會取代該國整份表）"
    imported: "已為 %{country} 匯入 %{count} 筆規則"
    errors_title: "匯入失敗——未儲存任何內容。請修正這些行："
    summary_title: "目前的對應表"
    zone_count: "%{zone}區：%{count} 段"
    empty: "尚未匯入任何郵編分區"
  # nav.shipping_zone_postal_rules: "郵編分區"
```

> Place each comment-marked key INTO the existing block at the right nesting (mirror the existing structure exactly; do not create duplicate `shipping_rate_cards:`/`nav:`/`columns:` blocks).

- [ ] **Step 5: Sidebar nav**

In `app/views/shared/_sidebar.html.erb`, after the shipping_rate_card_versions link block, add (same `has_permission?("shopify_stores")` gate, mirror the sibling link's markup):

```erb
          <% if current_membership&.has_permission?("shopify_stores") %>
            <%= link_to shipping_zone_postal_rules_path, data: { action: "click->sidebar#close" },
                class: "flex items-center gap-3 px-3 py-2 text-sm font-medium rounded-md #{current_page?(shipping_zone_postal_rules_path) ? 'bg-gray-100 text-gray-900' : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900'}" do %>
              <svg class="w-4 h-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" d="M15 10.5a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
                <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 10.5c0 7.142-7.5 11.25-7.5 11.25S4.5 17.642 4.5 10.5a7.5 7.5 0 1 1 15 0Z" />
              </svg>
              <%= t("nav.shipping_zone_postal_rules") %>
            <% end %>
          <% end %>
```

- [ ] **Step 6: Verify**

Run: `bin/rails runner "puts Rails.application.routes.url_helpers.import_shipping_zone_postal_rules_path; puts Rails.application.routes.url_helpers.import_shipping_rate_card_version_rates_path('x')"`
Expected: `/shipping_zone_postal_rules/import` and `/shipping_rate_card_versions/x/rates/import`.

Run: `bin/rails runner "%w[en zh-CN zh-TW].each { |l| I18n.with_locale(l) { [I18n.t('shipping_zone_postal_rules.title'), I18n.t('shipping_rate_cards.columns.zone'), I18n.t('nav.shipping_zone_postal_rules')].each { |v| raise \"missing #{l}\" if v.to_s.include?('translation missing') } }; puts \"#{l} ok\" }"`
Expected: `en ok` / `zh-CN ok` / `zh-TW ok`.

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/admin_controller.rb config/locales/en.yml config/locales/zh-CN.yml config/locales/zh-TW.yml app/views/shared/_sidebar.html.erb
git commit -m "feat: routes/authz/i18n/nav for postal zones + rate import"
```

---

## Task 8: `ShippingZonePostalRulesController`

**Files:**
- Create: `app/controllers/shipping_zone_postal_rules_controller.rb`
- Create: `app/views/shipping_zone_postal_rules/index.html.erb`
- Test: `spec/requests/shipping_zone_postal_rules_spec.rb`

- [ ] **Step 1: Write the failing request spec**

`spec/requests/shipping_zone_postal_rules_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "ShippingZonePostalRules", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let(:member_user) { create(:user) }
  let!(:member_membership) do
    create(:membership, company: company, user: member_user, role: :member, permissions: %w[shopify_stores])
  end

  describe "GET /shipping_zone_postal_rules" do
    it "renders for a member with shopify_stores permission" do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1")
      sign_in member_user
      patch switch_company_path(id: company.id)
      get shipping_zone_postal_rules_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /shipping_zone_postal_rules/import" do
    it "imports for an owner and replaces the country's map" do
      sign_in owner
      expect {
        post import_shipping_zone_postal_rules_path,
             params: { country_code: "AU", text: "1: 2000-2079\n2: 2080-2084" }
      }.to change { company.shipping_zone_postal_rules.where(country_code: "AU").count }.from(0).to(2)
      expect(response).to redirect_to(shipping_zone_postal_rules_path)
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      expect {
        post import_shipping_zone_postal_rules_path, params: { country_code: "AU", text: "1: 2000-2079" }
      }.not_to change(ShippingZonePostalRule, :count)
    end

    it "reports errors and saves nothing on bad input" do
      sign_in owner
      post import_shipping_zone_postal_rules_path, params: { country_code: "AU", text: "1: oops" }
      expect(company.shipping_zone_postal_rules.count).to eq(0)
      follow_redirect!
      expect(response.body).to include(I18n.t("shipping_zone_postal_rules.errors_title"))
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/requests/shipping_zone_postal_rules_spec.rb`
Expected: FAIL — missing controller.

- [ ] **Step 3: Write the controller**

`app/controllers/shipping_zone_postal_rules_controller.rb`:

```ruby
class ShippingZonePostalRulesController < AdminController
  before_action :require_owner!, only: [ :import ]

  def index
    rules = current_company.shipping_zone_postal_rules
    @countries = rules.distinct.pluck(:country_code).sort
    # summary: country -> { zone => count }
    @summary = rules.group(:country_code, :zone).count.each_with_object({}) do |((cc, zone), n), h|
      (h[cc] ||= {})[zone] = n
    end
  end

  def import
    result = PostalZoneImporter.new(
      company: current_company, country: params[:country_code], text: params[:text]
    ).call
    if result[:errors].empty?
      redirect_to shipping_zone_postal_rules_path,
                  notice: t("shipping_zone_postal_rules.imported", count: result[:count], country: params[:country_code])
    else
      flash[:import_errors] = result[:errors]
      redirect_to shipping_zone_postal_rules_path,
                  alert: t("shipping_zone_postal_rules.errors_title")
    end
  end

  private

  def require_owner!
    redirect_to(shipping_zone_postal_rules_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
```

- [ ] **Step 4: Write the index view**

`app/views/shipping_zone_postal_rules/index.html.erb`:

```erb
<div class="max-w-4xl mx-auto px-4 py-6">
  <h1 class="text-2xl font-semibold text-gray-900 mb-4"><%= t("shipping_zone_postal_rules.title") %></h1>

  <% if flash[:import_errors].present? %>
    <div class="mb-4 rounded border border-red-300 bg-red-50 p-3 text-sm text-red-700">
      <p class="font-medium"><%= t("shipping_zone_postal_rules.errors_title") %></p>
      <ul class="mt-1 list-disc list-inside">
        <% flash[:import_errors].each do |e| %><li><%= e %></li><% end %>
      </ul>
    </div>
  <% end %>

  <% if current_membership&.owner? %>
    <div class="bg-white border border-gray-200 rounded-lg shadow-sm p-5 mb-6">
      <h2 class="text-sm font-medium text-gray-700 mb-3"><%= t("shipping_zone_postal_rules.import_label") %></h2>
      <%= form_with url: import_shipping_zone_postal_rules_path, method: :post, local: true, class: "space-y-2" do %>
        <select name="country_code" class="border border-gray-300 rounded px-2 py-1 text-sm">
          <% ShippingRateCardVersion::COUNTRY_CODES.each do |c| %>
            <option value="<%= c %>"><%= t("shipping_rate_cards.countries.#{c}") %> (<%= c %>)</option>
          <% end %>
        </select>
        <p class="text-xs text-gray-500"><%= t("shipping_zone_postal_rules.au_hint") %> · <%= t("shipping_zone_postal_rules.ca_hint") %></p>
        <textarea name="text" rows="8" class="w-full border border-gray-300 rounded px-2 py-1 text-sm font-mono"></textarea>
        <button type="submit" class="px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700">
          <%= t("shipping_zone_postal_rules.import_button") %>
        </button>
      <% end %>
    </div>
  <% end %>

  <h2 class="text-sm font-medium text-gray-700 mb-2"><%= t("shipping_zone_postal_rules.summary_title") %></h2>
  <% if @summary.empty? %>
    <p class="text-sm text-gray-500"><%= t("shipping_zone_postal_rules.empty") %></p>
  <% else %>
    <% @summary.sort.each do |country, zones| %>
      <div class="mb-2 text-sm">
        <span class="font-medium"><%= t("shipping_rate_cards.countries.#{country}", default: country) %> (<%= country %>)</span>
        <span class="text-gray-600">
          — <%= zones.sort.map { |zone, n| t("shipping_zone_postal_rules.zone_count", zone: zone, count: n) }.join(" · ") %>
        </span>
      </div>
    <% end %>
  <% end %>
</div>
```

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec rspec spec/requests/shipping_zone_postal_rules_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/shipping_zone_postal_rules_controller.rb app/views/shipping_zone_postal_rules/index.html.erb spec/requests/shipping_zone_postal_rules_spec.rb
git commit -m "feat: add ShippingZonePostalRulesController + index/import UI"
```

---

## Task 9: Rate bulk-import action

**Files:**
- Modify: `app/controllers/shipping_rate_card_rates_controller.rb`
- Test: `spec/requests/shipping_rate_card_rates_spec.rb` (extend)

- [ ] **Step 1: Write the failing request spec additions**

Add to `spec/requests/shipping_rate_card_rates_spec.rb`:

```ruby
  describe "POST .../rates/import" do
    let!(:version) { create(:shipping_rate_card_version, company: company) }

    it "bulk-imports rates for an owner (replace)" do
      create(:shipping_rate_card_rate, version: version)  # wiped
      sign_in owner
      post import_shipping_rate_card_version_rates_path(shipping_rate_card_version_id: version.id),
           params: { text: "1,0,0.25,27,23\n2,0,0.25,27,31" }
      expect(version.rates.reload.count).to eq(2)
      expect(response).to redirect_to(shipping_rate_card_versions_path)
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      post import_shipping_rate_card_version_rates_path(shipping_rate_card_version_id: version.id),
           params: { text: "1,0,0.25,27,23" }
      expect(version.rates.reload.count).to eq(0)
    end

    it "reports errors and changes nothing on bad input" do
      create(:shipping_rate_card_rate, version: version)
      sign_in owner
      post import_shipping_rate_card_version_rates_path(shipping_rate_card_version_id: version.id),
           params: { text: "1,0.3,0.3,27,23" }
      expect(version.rates.reload.count).to eq(1)  # unchanged
    end
  end
```

> This spec assumes the file already defines `owner`, `company`, `member_user`, `member_membership` lets (it does — from the existing rates request spec). Reuse them; don't redefine.

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/requests/shipping_rate_card_rates_spec.rb -e "import"`
Expected: FAIL — no `import` action / route.

- [ ] **Step 3: Add the action**

In `app/controllers/shipping_rate_card_rates_controller.rb`, add `:import` to the `require_owner!` before_action list if it filters by action, add `set_version` for `:import`, and add the action. Concretely — update the before_actions and add the method:

```ruby
  before_action :require_owner!
  before_action :set_version
  before_action :set_rate, only: [ :update, :destroy ]

  def import
    result = RateCardRateImporter.new(version: @version, text: params[:text]).call
    if result[:errors].empty?
      redirect_to shipping_rate_card_versions_path,
                  notice: t("shipping_rate_cards.bulk_import_done", count: result[:count])
    else
      flash[:rate_import_errors] = result[:errors]
      redirect_to shipping_rate_card_versions_path,
                  alert: t("shipping_rate_cards.bulk_import_errors")
    end
  end
```

(The existing `set_version` already does `current_company.shipping_rate_card_versions.find(params[:shipping_rate_card_version_id])` — it covers `:import` because `import` is nested under the version. `require_owner!` already runs for all actions.)

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/requests/shipping_rate_card_rates_spec.rb`
Expected: PASS (new + existing).

- [ ] **Step 5: Commit**

```bash
git add app/controllers/shipping_rate_card_rates_controller.rb spec/requests/shipping_rate_card_rates_spec.rb
git commit -m "feat: rate bulk-import action on ShippingRateCardRatesController"
```

---

## Task 10: Rate cards UI — zone column + rate bulk import

**Files:**
- Modify: `app/views/shipping_rate_card_rates/_rate.html.erb`
- Modify: `app/views/shipping_rate_card_versions/_version.html.erb`

> The rate section is a CSS grid (`grid-cols-[1fr_1fr_1fr_1fr_auto]`). Add a Zone column → `grid-cols-[auto_1fr_1fr_1fr_1fr_auto]` (zone first). Update the header row, the `_rate` row, and the inline add-band form to match the new 6-column template, and add a rate bulk-import textarea.

- [ ] **Step 1: Update `_rate.html.erb`**

Read the current file, then change the grid template to 6 columns and add the zone cell first. Replace the whole file with:

```erb
<% owner = current_membership&.owner? %>
<div id="<%= dom_id(rate) %>" class="grid grid-cols-[auto_1fr_1fr_1fr_1fr_auto] gap-3 items-center px-5 py-2 border-b border-gray-50">
  <div class="text-gray-600 min-w-[3rem]"><%= rate.zone.presence || "—" %></div>
  <% if owner %>
    <% {
         weight_min_kg: "0.001", weight_max_kg: "0.001", per_kg_rate_cny: "0.01", flat_fee_cny: "0.01"
       }.each do |field, step| %>
      <div data-controller="cell-edit"
           data-cell-edit-url-value="<%= shipping_rate_card_version_rate_path(shipping_rate_card_version_id: version.id, id: rate.id) %>"
           data-cell-edit-param-value="shipping_rate_card_rate"
           data-cell-edit-field-value="<%= field %>"
           data-cell-edit-type-value="number"
           data-cell-edit-step-value="<%= step %>"
           data-cell-edit-min-value="0">
        <span data-cell-edit-target="display" tabindex="0" role="button"
              aria-label="<%= field.to_s.humanize %>"
              data-action="click->cell-edit#startEdit keydown.enter->cell-edit#startEdit keydown.space->cell-edit#startEdit">
          <%= rate.public_send(field) %>
        </span>
      </div>
    <% end %>
    <div>
      <%= button_to "🗑", shipping_rate_card_version_rate_path(shipping_rate_card_version_id: version.id, id: rate.id), method: :delete,
            form: { data: { turbo_confirm: t("shipping_rate_cards.rate_deleted") } },
            class: "text-gray-400 hover:text-red-600" %>
    </div>
  <% else %>
    <div class="text-gray-600"><%= rate.weight_min_kg %></div>
    <div class="text-gray-600"><%= rate.weight_max_kg %></div>
    <div class="text-gray-600"><%= rate.per_kg_rate_cny %></div>
    <div class="text-gray-600"><%= rate.flat_fee_cny %></div>
    <div></div>
  <% end %>
</div>
```

- [ ] **Step 2: Update `_version.html.erb` rate section**

Read the file. In the rate-bands section: (a) prepend a Zone header cell and switch both the header grid and the add-band form grid to `grid-cols-[auto_1fr_1fr_1fr_1fr_auto]`; (b) add a zone `<input>` as the first field of the add-band form; (c) sort rows by `[zone, weight_min_kg]`; (d) add a rate bulk-import textarea after the add-band form (owner-only). Replace the header `<div class="grid ...">` and the `version.rates.sort_by...` line and the add-band `form_with` block:

Header row — change to:
```erb
    <div class="grid grid-cols-[auto_1fr_1fr_1fr_1fr_auto] gap-3 items-center px-5 py-2 text-left text-gray-500 border-b border-gray-100">
      <span><%= t("shipping_rate_cards.columns.zone") %></span>
      <span><%= t("shipping_rate_cards.columns.weight_min") %></span>
      <span><%= t("shipping_rate_cards.columns.weight_max") %></span>
      <span><%= t("shipping_rate_cards.columns.per_kg") %></span>
      <span><%= t("shipping_rate_cards.columns.flat_fee") %></span>
      <span></span>
    </div>
```

Rows ordering — change:
```erb
      <% version.rates.sort_by { |r| [ r.zone.to_s, r.weight_min_kg ] }.each do |rate| %>
        <%= render "shipping_rate_card_rates/rate", version: version, rate: rate %>
      <% end %>
```

Add-band form — change to (zone input first, 6-col grid):
```erb
      <%= form_with url: shipping_rate_card_version_rates_path(shipping_rate_card_version_id: version.id), method: :post, local: true,
                    class: "grid grid-cols-[auto_1fr_1fr_1fr_1fr_auto] gap-3 items-center px-5 py-3 border-t border-gray-100" do %>
        <input type="text" name="shipping_rate_card_rate[zone]"
               placeholder="<%= t('shipping_rate_cards.columns.zone') %>"
               class="w-16 border border-gray-300 rounded px-2 py-1 text-sm">
        <input type="number" step="0.001" min="0" name="shipping_rate_card_rate[weight_min_kg]"
               placeholder="<%= t('shipping_rate_cards.columns.weight_min') %>" required
               class="w-full border border-gray-300 rounded px-2 py-1 text-sm">
        <input type="number" step="0.001" min="0" name="shipping_rate_card_rate[weight_max_kg]"
               placeholder="<%= t('shipping_rate_cards.columns.weight_max') %>" required
               class="w-full border border-gray-300 rounded px-2 py-1 text-sm">
        <input type="number" step="0.01" min="0" name="shipping_rate_card_rate[per_kg_rate_cny]"
               placeholder="<%= t('shipping_rate_cards.columns.per_kg') %>" required
               class="w-full border border-gray-300 rounded px-2 py-1 text-sm">
        <input type="number" step="0.01" min="0" name="shipping_rate_card_rate[flat_fee_cny]"
               placeholder="<%= t('shipping_rate_cards.columns.flat_fee') %>" value="0" required
               class="w-full border border-gray-300 rounded px-2 py-1 text-sm">
        <button type="submit"
                class="px-3 py-1 text-sm bg-blue-600 text-white rounded hover:bg-blue-700 whitespace-nowrap">
          <%= t("shipping_rate_cards.add_band") %>
        </button>
      <% end %>
```

Add a rate bulk-import block right after that form (still inside `<% if owner %>`):
```erb
      <%= form_with url: import_shipping_rate_card_version_rates_path(shipping_rate_card_version_id: version.id), method: :post, local: true,
                    class: "px-5 py-3 border-t border-gray-100 space-y-2" do %>
        <p class="text-xs text-gray-500"><%= t("shipping_rate_cards.bulk_import_rates_hint") %></p>
        <textarea name="text" rows="4" class="w-full border border-gray-300 rounded px-2 py-1 text-sm font-mono"></textarea>
        <button type="submit" class="px-3 py-1 text-sm bg-gray-700 text-white rounded hover:bg-gray-800">
          <%= t("shipping_rate_cards.bulk_import_rates") %>
        </button>
      <% end %>
```

> The existing `shipping_rate_card_rate` strong params (`permit(:weight_min_kg, :weight_max_kg, :per_kg_rate_cny, :flat_fee_cny)`) must now also permit `:zone` for the inline add-band form. Update `rate_params` in `app/controllers/shipping_rate_card_rates_controller.rb` to `permit(:zone, :weight_min_kg, :weight_max_kg, :per_kg_rate_cny, :flat_fee_cny)`.

- [ ] **Step 3: Permit `:zone` in rate params**

In `app/controllers/shipping_rate_card_rates_controller.rb`:
```ruby
  def rate_params
    params.require(:shipping_rate_card_rate).permit(:zone, :weight_min_kg, :weight_max_kg, :per_kg_rate_cny, :flat_fee_cny)
  end
```

- [ ] **Step 4: Verify views render (re-run request specs that render them)**

Run: `bundle exec rspec spec/requests/shipping_rate_card_versions_spec.rb spec/requests/shipping_rate_card_rates_spec.rb`
Expected: PASS (index renders the version card with the new zone column + bulk-import form; inline add-band still works with the zone field).

- [ ] **Step 5: Commit**

```bash
git add app/views/shipping_rate_card_rates/_rate.html.erb app/views/shipping_rate_card_versions/_version.html.erb app/controllers/shipping_rate_card_rates_controller.rb
git commit -m "feat: zone column + rate bulk-import in rate cards UI"
```

---

## Task 11: System spec

**Files:**
- Test: `spec/system/shipping_zone_postal_rules_spec.rb`

> Mirror the existing `spec/system/shipping_rate_cards_spec.rb` conventions (driver configured globally in rails_helper; login via `sign_in_as(owner)`; `I18n.t` not `t`; select-by-option-value to avoid locale dependence).

- [ ] **Step 1: Write the system spec**

`spec/system/shipping_zone_postal_rules_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Postal zones", type: :system do
  let(:owner) { create(:user) }

  before { sign_in_as(owner) }

  it "imports an AU postal map and shows the summary" do
    visit shipping_zone_postal_rules_path

    find("select[name='country_code'] option[value='AU']").select_option
    fill_in "text", with: "1: 2000-2079, 2158\n2: 2080-2084"
    click_button I18n.t("shipping_zone_postal_rules.import_button")

    expect(page).to have_content(I18n.t("shipping_zone_postal_rules.imported", count: 3, country: "AU"))
    company = owner.companies.first
    expect(company.shipping_zone_postal_rules.where(country_code: "AU").count).to eq(3)
    # summary line shows zone counts
    expect(page).to have_content("zone 1")
  end
end
```

- [ ] **Step 2: Run the system spec**

Run: `bundle exec rspec spec/system/shipping_zone_postal_rules_spec.rb`
Expected: PASS. (If the environment's first system example fails with a Selenium "no chrome binary"/SessionNotCreatedError cold-start, re-run after a warm-up spec, e.g. `bundle exec rspec spec/system/shipping_rate_cards_spec.rb spec/system/shipping_zone_postal_rules_spec.rb`, and judge by the postal-zones example.)

- [ ] **Step 3: Commit**

```bash
git add spec/system/shipping_zone_postal_rules_spec.rb
git commit -m "test: system spec for postal zone import"
```

---

## Task 12: Full suite + lint gate

**Files:** none (verification only)

- [ ] **Step 1: Full non-system suite**

Run: `bundle exec rspec --exclude-pattern "spec/system/**/*"`
Expected: all green; coverage ≥ 95%.

- [ ] **Step 2: System suite (warm Chrome)**

Run: `bundle exec rspec spec/system` (re-run once if the first example hits the cold-start Selenium artifact).
Expected: all green on the warm run.

- [ ] **Step 3: Lint + security**

Run: `bin/rubocop && bin/brakeman --no-pager && bin/bundler-audit`
Expected: no offenses; no warnings; no vulnerabilities.

- [ ] **Step 4: Fix anything, then commit (only if fixes were needed)**

```bash
git add -A
git commit -m "chore: lint/suite clean for zone-based shipping rates"
```

---

## Self-Review

**Spec coverage:**
- ✅ `zone` column + `shipping_zone_postal_rules` table (Task 1)
- ✅ `PostalNormalizer` AU/CA normalize + range_for (Task 2)
- ✅ `ShippingZonePostalRule` zone_for / country_zoned? / most-specific-wins (Task 3)
- ✅ Calculator zone resolution + flat backward-compat (Task 4)
- ✅ Postal bulk import (AU/CA), replace + error reporting (Task 5)
- ✅ Rate bulk import, replace + error reporting (Task 6)
- ✅ Routes / authz / i18n×3 / nav (Task 7)
- ✅ Postal rules controller + index/import UI + summary (Task 8)
- ✅ Rate import action (Task 9)
- ✅ Zone column + rate bulk-import in rate-card UI (Task 10)
- ✅ System spec (Task 11); full gate (Task 12)
- ✅ Per-country optional / flat unchanged (Task 4 flat path + existing specs)
- ✅ No-match → nil (Task 4 `:unmatched`)
- ✅ Postal map shared per country, not versioned (Task 1/5 — single table, replace)
- ✅ Service still via version; zone on rate (Task 4 lookup)

**Placeholder scan:** No TBD/TODO; every code step has full code; test code is concrete.

**Type/name consistency:** `PostalNormalizer.normalize(country, raw)` / `.range_for(country, token)`; `ShippingZonePostalRule.zone_for(company:, country:, key:)` / `.country_zoned?(company:, country:)`; importer return shape `{ count:, errors: }` used identically in services + controllers; calculator `resolve_zone` returns `:flat` / zone-string / `:unmatched`; rate lookup `version.rates.where(zone: ...).for_weight(kg)`; grid template `grid-cols-[auto_1fr_1fr_1fr_1fr_auto]` used in header + `_rate` + add-band form. Consistent across tasks.

**Known adaptation points (call out at execution, not placeholders):** the calculator spec additions reuse the existing file's `company`/`store`/`customer` lets; the rate-import request spec reuses the existing `owner`/`company`/`member_user` lets; i18n additions go INTO existing blocks. Each task states this.
