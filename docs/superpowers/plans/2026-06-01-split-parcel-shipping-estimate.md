# Split-Parcel Shipping Cost Estimate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an order's total weight exceeds the applicable rate version/zone's max band weight, estimate cost by greedily splitting into parcels at that max, charging each parcel its own per-kg + handling fee, and summing.

**Architecture:** A single self-contained change in `ShippingCostCalculator`: load the zone-scoped bands once, and replace the inline single-band cost with a `cost_cny_for(bands, weight_kg)` that does a single-parcel lookup when a band matches, else (when over the max band) a greedy weight-split. No schema/model/controller/view/i18n changes.

**Tech Stack:** Rails 8.1, RSpec + FactoryBot.

**Spec:** `docs/superpowers/specs/2026-06-01-split-parcel-shipping-estimate-design.md`

**Conventions (verified):**
- `bin/rails`/`bundle`/`rspec` need ruby on PATH: `export PATH="/home/simon/.rubies/ruby-3.4.7/bin:$PATH"`.
- SimpleCov fails single-file runs with exit 2 (global 95% gate) — EXPECTED; judge by `N examples, M failures`.
- Branch: `feature/shipping-cost-split-parcel` (already created off main; spec committed there). Do NOT switch branches.
- The store in the existing calculator spec has `cost_fx_rate: 7.0, default_service_type: "with_battery"`; reuse the file's existing `company`/`store`/`customer` lets.
- `for_weight` band semantics: `weight_min_kg < W AND weight_max_kg >= W` (so W == max matches the top band).

---

## Task 1: Split-parcel cost in `ShippingCostCalculator`

**Files:**
- Modify: `app/services/shipping_cost_calculator.rb`
- Test: `spec/services/shipping_cost_calculator_spec.rb` (extend)

- [ ] **Step 1: Write the failing spec additions**

Read `spec/services/shipping_cost_calculator_spec.rb` first to match its style and reuse its `let(:company)`, `let(:store)` (cost_fx_rate 7.0, default_service_type "with_battery"), `let(:customer)`. Then ADD this `describe` block inside the top-level `RSpec.describe ShippingCostCalculator` block:

```ruby
  describe "over-max orders split into parcels" do
    # US flat version, bands: 0–1kg (¥27/kg, ¥23) and 1–5kg (¥30/kg, ¥25); max band = 5kg.
    let(:version) do
      create(:shipping_rate_card_version, company: company, country_code: "US",
             service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
    end

    before do
      create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 0, weight_max_kg: 1, per_kg_rate_cny: 27, flat_fee_cny: 23)
      create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 1, weight_max_kg: 5, per_kg_rate_cny: 30, flat_fee_cny: 25)
    end

    def us_order(grams:)
      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     shopify_data: { "shipping_address" => { "country_code" => "US" } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: grams)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      order
    end

    it "splits into 5kg + 0.5kg parcels, each with its own handling fee, using each parcel's band" do
      # 5kg → band 1–5: 5*30+25 = 175 ; 0.5kg → band 0–1: 0.5*27+23 = 36.5 ; sum 211.5 / 7.0 = 30.21
      expect(ShippingCostCalculator.estimate(us_order(grams: 5500))).to eq(30.21)
    end

    it "handles an exact multiple of the max (10kg → 5 + 5)" do
      # 2 × (5*30+25 = 175) = 350 / 7.0 = 50.0
      expect(ShippingCostCalculator.estimate(us_order(grams: 10_000))).to eq(50.0)
    end

    it "splits into three parcels (12kg → 5 + 5 + 2)" do
      # 175 + 175 + (2*30+25 = 85) = 435 / 7.0 = 62.14 (62.142857… rounds to 62.14)
      expect(ShippingCostCalculator.estimate(us_order(grams: 12_000))).to eq(62.14)
    end

    it "does not split an order at exactly the max (5kg → single parcel)" do
      # band 1–5: 5*30+25 = 175 / 7.0 = 25.0
      expect(ShippingCostCalculator.estimate(us_order(grams: 5000))).to eq(25.0)
    end

    it "returns nil when a remainder parcel matches no band (below the lowest min)" do
      # Replace bands with a set whose lowest min is 0.5, so a 0.4kg remainder matches nothing.
      version.rates.delete_all
      create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 0.5, weight_max_kg: 1, per_kg_rate_cny: 27, flat_fee_cny: 23)
      create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 1, weight_max_kg: 5, per_kg_rate_cny: 30, flat_fee_cny: 25)
      # 5.4kg → 5kg parcel (band 1–5) + 0.4kg remainder → no band → nil
      expect(ShippingCostCalculator.estimate(us_order(grams: 5400))).to be_nil
    end

    it "splits a zoned (AU) over-max order using that zone's bands" do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1", postal_start: "2000", postal_end: "2079")
      au_version = create(:shipping_rate_card_version, company: company, country_code: "AU",
                          service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: au_version, zone: "1", weight_min_kg: 0, weight_max_kg: 1, per_kg_rate_cny: 27, flat_fee_cny: 23)
      create(:shipping_rate_card_rate, version: au_version, zone: "1", weight_min_kg: 1, weight_max_kg: 5, per_kg_rate_cny: 30, flat_fee_cny: 25)

      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     shopify_data: { "shipping_address" => { "country_code" => "AU", "zip" => "2075" } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 5500)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      # zone-1 bands, 5.5kg → 5 (1–5) + 0.5 (0–1) = 211.5 / 7.0 = 30.21
      expect(ShippingCostCalculator.estimate(order)).to eq(30.21)
    end
  end
```

- [ ] **Step 2: Run to verify the new examples fail**

Run: `bundle exec rspec spec/services/shipping_cost_calculator_spec.rb -e "over-max"`
Expected: the split examples FAIL — the current calculator returns nil for over-max weights (no band) instead of splitting.

- [ ] **Step 3: Modify the calculator**

In `app/services/shipping_cost_calculator.rb`, replace this part of `call`:

```ruby
    zone = resolve_zone(country)   # nil = unzoned country, String = matched zone, :unmatched = give up
    return nil if zone == :unmatched

    rate = version.rates.where(zone: zone).for_weight(weight_kg).first
    return nil unless rate

    cost_cny = (weight_kg * rate.per_kg_rate_cny) + rate.flat_fee_cny
    (cost_cny / @store.cost_fx_rate).round(2)
  end
```

with:

```ruby
    zone = resolve_zone(country)   # nil = unzoned country, String = matched zone, :unmatched = give up
    return nil if zone == :unmatched

    bands = version.rates.where(zone: zone).to_a
    cost_cny = cost_cny_for(bands, weight_kg)
    return nil unless cost_cny

    (cost_cny / @store.cost_fx_rate).round(2)
  end
```

Add these private methods (next to the other private helpers, e.g. after `total_weight_kg`):

```ruby
  # Cost in CNY for a weight against a set of bands. If the weight exceeds the
  # heaviest band, simulate a greedy split into parcels at the max band weight,
  # charging each parcel its own per-kg charge + handling fee. Returns nil if any
  # parcel's weight matches no band.
  def cost_cny_for(bands, weight_kg)
    band = band_for(bands, weight_kg)
    return parcel_cost(band, weight_kg) if band

    max = bands.map(&:weight_max_kg).max
    return nil unless max && weight_kg > max

    total = BigDecimal("0")
    remaining = weight_kg
    while remaining > max
      full = band_for(bands, max)
      return nil unless full
      total += parcel_cost(full, max)
      remaining -= max
    end
    if remaining > 0
      rem = band_for(bands, remaining)
      return nil unless rem
      total += parcel_cost(rem, remaining)
    end
    total
  end

  def band_for(bands, weight_kg)
    bands.find { |b| b.weight_min_kg < weight_kg && b.weight_max_kg >= weight_kg }
  end

  def parcel_cost(band, weight_kg)
    (weight_kg * band.per_kg_rate_cny) + band.flat_fee_cny
  end
```

Notes:
- `band_for` is the in-memory equivalent of the `for_weight` scope (`min < W AND max >= W`), so a parcel at exactly `max` matches the top band.
- Loading `bands` once (`.to_a`) avoids N+1 in the split loop.
- `max` is the heaviest `weight_max_kg`; `weight_kg > max` is the only trigger for splitting (below-min / gap / no-bands still return nil via the early `band_for` miss + this guard).

- [ ] **Step 4: Run to verify all pass**

Run: `bundle exec rspec spec/services/shipping_cost_calculator_spec.rb`
Expected: PASS — the new over-max examples AND every pre-existing example (single-band lookups return the identical cost via `parcel_cost`; flat/zoned/`:unmatched`/nil paths unchanged).

- [ ] **Step 5: RuboCop**

Run: `bin/rubocop app/services/shipping_cost_calculator.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add app/services/shipping_cost_calculator.rb spec/services/shipping_cost_calculator_spec.rb
git commit -m "feat: split over-max orders into parcels for shipping estimate"
```

---

## Task 2: Full suite + lint gate

**Files:** none (verification only)

- [ ] **Step 1: Full non-system suite**

Run: `bundle exec rspec --exclude-pattern "spec/system/**/*"`
Expected: all green; coverage ≥ 95%. (Confirms no regression to calculator/sync/backfill/dashboard specs from the cost refactor.)

- [ ] **Step 2: Lint + security**

Run: `bin/rubocop && bin/brakeman --no-pager && bin/bundler-audit`
Expected: no offenses; no warnings; no vulnerabilities.

- [ ] **Step 3: Fix anything, then commit (only if fixes were needed)**

```bash
git add -A
git commit -m "chore: lint/suite clean for split-parcel estimate"
```

---

## Self-Review

**Spec coverage:**
- ✅ Over-max → greedy split at max band (Task 1: 5.5kg → 5+0.5, 12kg → 5+5+2)
- ✅ Per-parcel handling fee (the 5.5kg test asserts the explicit two-flat sum 211.5)
- ✅ Each parcel uses its own band (5kg→1–5 band, 0.5kg→0–1 band)
- ✅ Exact multiple (10kg → 5+5, no remainder)
- ✅ At/under max unchanged (5kg single parcel; pre-existing examples)
- ✅ Remainder below lowest min → nil
- ✅ Zoned over-max splits using the zone's bands
- ✅ Trigger only on `weight > max` (below-min/gap/no-bands → nil, unchanged)
- ✅ No schema/model/controller/view/i18n change (single-file calculator)

**Placeholder scan:** none — full code + concrete test values (chosen with exactly-representable floats: 5.5−5=0.5, 12−5=7, 7−5=2; avoids float drift in assertions).

**Type/name consistency:** `cost_cny_for(bands, weight_kg)` / `band_for(bands, weight_kg)` / `parcel_cost(band, weight_kg)` used consistently; `bands = version.rates.where(zone: zone).to_a`; result `(cost_cny / @store.cost_fx_rate).round(2)` matches the existing final step.
