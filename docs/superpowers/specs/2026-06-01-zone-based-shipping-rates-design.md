# Zone-Based (Postal-Zone) Shipping Rates — Design

**Date**: 2026-06-01
**Status**: Draft for review
**Builds on**: `2026-05-31-shipping-cost-and-net-margin-design.md` (the country-level estimated shipping cost feature, now in production)

## Goal

Extend shipping rate cards to support **postal-zone-based pricing** for countries that the carrier prices by region. For such a country (e.g. Australia, Canada), the rate depends on which **zone** the order's shipping postal code falls into, and then on the weight band within that zone. Countries that price flat by country (e.g. the US) keep the existing behavior unchanged.

This is **additive and per-country**: a country either has a postal→zone map (→ zone-based pricing) or it doesn't (→ existing flat country-level pricing).

## Decisions captured during brainstorming

| Decision | Choice |
|---|---|
| Coexistence | Per-country optional. A country with a postal→zone map is priced by zone; a country without one keeps the current flat country-level rate. Fully backward compatible. AU + CA are zone-based now; US etc. stay flat. |
| Postal→zone data entry | **Bulk paste/CSV import**, per country (the maps are large: hundreds of AU ranges, thousands of CA prefixes). |
| Rate data entry | Rate rows (zone × weight band) also support **bulk import** (a version can be ~52 rows). |
| No-match fallback | If a zone-based country's order postal matches no zone (or has no postal) → return `nil` (uncovered), consistent with the existing "missing input → nil" behavior. No default zone. |
| Service × zone | The postal→zone map is **shared per country** (all services use it). Rates still differ by service (via the version's `service_type`) and now also by zone. |
| Versioning | Rates keep the existing named-version + effective-date model. The postal→zone map is a **single current table per country** (re-import replaces it), NOT versioned — order snapshots are frozen at sync, so historical correctness is already preserved. |
| Postal matching | Normalize postal to a **fixed-width, lexicographically-sortable key**; each rule is a `[postal_start, postal_end]` range; the matching rule is the one containing the key with the **greatest `postal_start`** (most specific wins). |

## Postal normalization & matching (the core algorithm)

A single PORO `PostalNormalizer` is used in **two** places — at import (rule endpoints → normalized keys) and at lookup (order postal → normalized key) — so they always agree.

### Australia (numeric)
- Strip whitespace. Must be all digits. Length 1–4 → **zero-pad to 4** (`"200"` → `"0200"`, `"2158"` → `"2158"`). Length > 4 or non-numeric → invalid (`nil`).
- A range `1000-1935` → start `"1000"`, end `"1935"`. A single value `2158` → start = end = `"2158"`.
- Example: postal `2075` → key `"2075"` ∈ `["2000","2079"]` (zone 1) → **zone 1**.

### Canada (alphanumeric; FSA = first 3, LDU = last 3)
- Uppercase, strip non-alphanumeric. Length 6 → use as-is. Length 3 → treat as FSA, pad `"000"` for the lookup key (`"G0A"` → `"G0A000"`). Other lengths → invalid (`nil`).
- **3-char rule** (whole FSA): `V9N` → start `"V9N000"`, end `"V9NZZZ"`.
- **6-char rule** (sub-range within an FSA): `G0A4V0` → start `"G0A4V0"`, end `"G0AZZZ"` (the FSA's max).
- ASCII ordering: `'0'..'9' < 'A'..'Z'`, so `'Z'` is the maximal LDU character and `"<FSA>ZZZ"` is a valid FSA upper bound.
- Overlap resolution: among rules whose `[start,end]` contains the key, pick the one with the **greatest `start`** (most specific). Example: `G0A5A0` falls in both `G0A000–G0AZZZ` (FSA rule) and `G0A4V0–G0AZZZ` (sub-rule); the sub-rule's start `G0A4V0` > `G0A000`, so the **sub-rule wins**.

### Lookup
```
key = PostalNormalizer.normalize(country, raw_postal)
# returns nil if raw_postal can't be normalized for that country
rule = rules.where(country).where("postal_start <= :k AND postal_end >= :k", k: key)
            .order(postal_start: :desc).first
zone = rule&.zone
```

## Schema

### `shipping_rate_card_rates` — add `zone`
```ruby
add_column :shipping_rate_card_rates, :zone, :string  # nullable
add_index  :shipping_rate_card_rates, [:version_id, :zone]
```
- `zone = NULL` → flat country-level rate (unchanged behavior).
- `zone = "1"/"2"/…` → zone-based rate. A version's rates now span zones × weight bands.
- Zone is a short string (the zone number as text). No global inclusion validation (zones are defined per country by the postal map); the rate-entry UI offers the zones found in that country's postal rules.

### New table `shipping_zone_postal_rules`
```ruby
create_table :shipping_zone_postal_rules, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.uuid   :company_id, null: false
  t.string :country_code, null: false       # ISO-3166-1 alpha-2, e.g. "AU", "CA"
  t.string :zone, null: false               # "1", "2", …
  t.string :postal_start, null: false       # normalized fixed-width key
  t.string :postal_end, null: false         # normalized fixed-width key (>= postal_start)
  t.timestamps
end
add_index :shipping_zone_postal_rules, [:company_id, :country_code, :postal_start],
          name: "idx_zone_postal_lookup"
add_foreign_key :shipping_zone_postal_rules, :companies
```
- "Single current table per country": importing a country **replaces all rows** for `(company_id, country_code)` in one transaction.
- Normalized keys are fixed-width strings → SQL string comparison is correct.

## Models

```ruby
class ShippingZonePostalRule < ApplicationRecord
  belongs_to :company

  validates :country_code, :zone, :postal_start, :postal_end, presence: true
  validate  :end_not_before_start

  # Returns the zone string for a normalized key, or nil if no rule matches.
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
    errors.add(:postal_end, "must be >= postal_start") if postal_end < postal_start
  end
end
```

Extension to `ShippingRateCardRate`:
```ruby
# for_weight scope unchanged; zone is filtered by the caller via where(zone:)
# (calculator does version.rates.where(zone: zone).for_weight(kg).first)
```

## `PostalNormalizer` (new PORO)

```ruby
class PostalNormalizer
  # country -> normalized fixed-width key, or nil if not normalizable.
  def self.normalize(country, raw)
    return nil if raw.blank?
    case country
    when "AU" then normalize_au(raw)
    when "CA" then normalize_ca(raw)
    else nil   # countries without a postal map don't normalize
    end
  end

  # For a single rule token at import time, return [start_key, end_key] or nil.
  def self.range_for(country, token)
    case country
    when "AU" then range_au(token)   # "1000-1935" or "2158"
    when "CA" then range_ca(token)   # "G0A4V0" (len 6) or "G0B" (len 3)
    else nil
    end
  end

  # --- AU ---
  def self.normalize_au(raw)
    s = raw.to_s.gsub(/\s/, "")
    return nil unless s.match?(/\A\d{1,4}\z/)
    s.rjust(4, "0")
  end

  def self.range_au(token)
    if token.include?("-")
      a, b = token.split("-", 2).map { |x| normalize_au(x) }
      (a && b && b >= a) ? [a, b] : nil
    else
      v = normalize_au(token); v && [v, v]
    end
  end

  # --- CA ---
  def self.normalize_ca(raw)
    s = raw.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    case s.length
    when 6 then s
    when 3 then "#{s}000"   # FSA-only order postal → lowest in FSA
    else nil
    end
  end

  def self.range_ca(token)
    s = token.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    case s.length
    when 3 then ["#{s}000", "#{s}ZZZ"]            # whole FSA
    when 6 then [s, "#{s[0,3]}ZZZ"]               # sub-range within FSA
    else nil
    end
  end
end
```

## Calculator changes (`ShippingCostCalculator`)

Insert a zone-resolution step between finding the version and finding the rate:

```ruby
def call
  return nil unless @store&.cost_fx_rate&.positive?
  return nil unless @store.default_service_type.present?
  return nil unless @order.ordered_at

  country = country_code_from_order
  return nil unless country

  weight_kg = total_weight_kg
  return nil unless weight_kg && weight_kg.positive?

  version = ShippingRateCardVersion.lookup(
    company: @store.company, country: country,
    service_type: @store.default_service_type, on_date: @order.ordered_at.to_date
  )
  return nil unless version

  zone = resolve_zone(country)          # NEW — :flat, a zone string, or :unmatched
  return nil if zone == :unmatched

  rate = version.rates.where(zone: (zone == :flat ? nil : zone)).for_weight(weight_kg).first
  return nil unless rate

  cost_cny = (weight_kg * rate.per_kg_rate_cny) + rate.flat_fee_cny
  (cost_cny / @store.cost_fx_rate).round(2)
end

private

def resolve_zone(country)
  return :flat unless ShippingZonePostalRule.country_zoned?(company: @store.company, country: country)
  key = PostalNormalizer.normalize(country, postal_from_order)
  return :unmatched unless key
  zone = ShippingZonePostalRule.zone_for(company: @store.company, country: country, key: key)
  zone || :unmatched
end

def postal_from_order
  @order.shopify_data&.dig("shipping_address", "zip") ||
    @order.shopify_data&.dig("billing_address", "zip")
end
```

- Flat countries: `resolve_zone` returns `:flat` → rate lookup with `zone: nil` → existing behavior, unchanged.
- Zoned country, postal matches → zone string → rate lookup with that zone.
- Zoned country, postal missing/unnormalizable/no-match → `:unmatched` → `nil` (uncovered).

Sync, backfill, dashboard, coverage: **no change** — they already treat a `nil` estimate as uncovered.

## Imports

Two bulk-import parsers; each runs in a transaction and **replaces** the relevant rows on success, or reports per-line errors and writes nothing on failure.

### Postal→zone import (per country)
Endpoint: `POST /shipping_zone_postal_rules/import` with `country_code` + `text`.
- **AU input** — one line per zone: `<zone>: <comma-separated ranges/values>`
  ```
  1: 1000-1935, 2000-2079, 2158, 2160-2172
  2: 2080-2084, 2108, 200-299
  ```
- **CA input** — one line per rule: `<token>,<zone>` (3- or 6-char token; length inferred)
  ```
  G0A4V0,1
  G0B,1
  V9N,2
  ```
- Parser: for each token, `PostalNormalizer.range_for(country, token)` → `[start,end]`; build rows `(zone, start, end)`. Collect line errors (bad token, bad range, unknown country). On zero errors: delete existing `(company, country)` rows, insert new ones (single transaction). On any error: abort, return the list of bad lines.

### Rate bulk import (per version)
Endpoint: `POST /shipping_rate_card_versions/:id/rates/import` with `text`.
- Input — one line per rate: `<zone>,<min_kg>,<max_kg>,<per_kg_cny>,<flat_fee_cny>` (blank zone = flat)
  ```
  1,0,0.25,27,23
  1,0.251,0.3,27,23
  2,0,0.25,27,31
  ```
- Parser: validate numerics + `max > min`; build `ShippingRateCardRate` rows for the version. On zero errors: **replace** that version's rates (delete + insert) in a transaction. On error: abort, list bad lines.
- (Inline add/edit of individual rate rows remains available as before.)

## UI

### Shipping rate cards page (existing `/shipping_rate_card_versions`)
- Each rate row gains a **Zone** column. For a version whose country is zoned, rows are grouped by zone; the inline add-band form and the cell-edit cells include zone (zone as a dropdown of the country's known zones, derived from its postal rules; blank for flat countries).
- A **"Bulk import rates"** textarea per version (owner-only) using the format above.

### Postal zones page (new, e.g. `/shipping_zone_postal_rules`)
- Owner-only. Per country: a **bulk-import textarea** (with the country-appropriate format hint) + a **summary of current rules** (counts per zone, e.g. "AU — zone 1: 142 ranges · zone 2: 98 · …"). Full per-row listing is paginated/searchable (CA can have thousands of rows); do NOT render all rows at once.
- Sidebar nav entry gated on the same `shopify_stores` permission.

## Authorization
- New controllers (`ShippingZonePostalRulesController`, the rates `import` action) follow the existing pattern: page viewable by members with `shopify_stores` permission; mutations (import) owner-only. `PERMISSION_KEY_MAP` gains `"shipping_zone_postal_rules" => "shopify_stores"`.

## I18n (en / zh-CN / zh-TW)
- `shipping_zone_postal_rules.*` (title, import labels, format hints per country, summary, errors), `shipping_rate_cards.columns.zone`, `shipping_rate_cards.bulk_import_*`, `nav.shipping_zone_postal_rules`.

## Testing

### `postal_normalizer_spec.rb`
- AU: `"200"`→`"0200"`, `"2158"`→`"2158"`, `"12345"`→nil, `"AB"`→nil; `range_for` for `"1000-1935"`, `"2158"`, bad ranges.
- CA: `"g0a 4v0"`→`"G0A4V0"`, `"G0A"`→`"G0A000"`, bad length→nil; `range_for` for `"V9N"`→`["V9N000","V9NZZZ"]`, `"G0A4V0"`→`["G0A4V0","G0AZZZ"]`.

### `shipping_zone_postal_rule_spec.rb`
- `zone_for`: AU numeric containment; CA FSA rule; CA overlap → most-specific (greatest start) wins; cross-FSA boundary; no match → nil; scoped by company.
- `country_zoned?` true/false.
- validations + `end_not_before_start`.

### `shipping_cost_calculator_spec.rb` (extend)
- Flat country (no postal rules) → unchanged (existing examples still pass; rates use `zone: nil`).
- Zoned country (AU): order in zone 1 → zone-1 rate; order in zone 2 → zone-2 rate.
- Zoned country (CA): FSA + sub-range cases resolve to the right zone.
- Zoned country, postal missing / unmatched → nil.
- Zoned country exists but version has no row for that zone → nil.

### Import specs (request)
- Postal import (AU/CA): valid text → replaces rows, correct normalized keys; bad lines → aborted + error list; cross-company isolation; owner-gated.
- Rate bulk import: valid → replaces version rates; bad lines → aborted; owner-gated.

### System spec
- Import AU postal zones via paste; bulk-import AU rates; verify a version shows zone-grouped rows.

## Out of scope
- Postal→zone map versioning/history (single current table; snapshots already freeze cost).
- Zone maps for countries other than AU/CA (added later by importing their maps).
- Carrier "min chargeable weight" / rounding step (unchanged; weight used as-is).
- Per-service postal maps (map is shared per country).

## Rollout / operator steps
1. Deploy migration (`zone` column + `shipping_zone_postal_rules` table).
2. Owner: `/shipping_zone_postal_rules` → paste each zoned country's postal→zone map (AU, CA).
3. Owner: in each zoned country's rate version, bulk-import the zone × weight-band rates.
4. New orders auto-snapshot zone-based estimates; run `BackfillOrderLineItemsService.new(store).call` to fill historical (and to re-fill orders previously left NULL because the country had no rates yet).
5. Watch the dashboard shipping coverage %.
