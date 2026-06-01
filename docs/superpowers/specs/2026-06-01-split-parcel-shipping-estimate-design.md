# Split-Parcel Shipping Cost Estimate — Design

**Date**: 2026-06-01
**Status**: Draft for review
**Builds on**: `2026-05-31-shipping-cost-and-net-margin-design.md` + `2026-06-01-zone-based-shipping-rates-design.md` (both in production)

## Problem

An order's total weight can exceed the carrier's maximum single-parcel weight. Example seen in production: an order of 7 × 900 g = 6.3 kg shipped via the US channel, whose rate card tops out at 5 kg. `ShippingRateCardRate.for_weight(6.3)` matches no band → `ShippingCostCalculator` returns `nil` → the order is uncovered (shipping treated as 0, dashboard coverage dips).

In reality such an order is **split into multiple parcels** (each within the carrier max) and shipped separately — each parcel incurs its own per-kg charge **and its own handling fee**. A future feature will record actual per-parcel costs (parcel/tracking numbers tied to an order); until then we only need a sensible **estimate (budget)** for over-max orders.

## Goal

When an order's total weight exceeds the applicable rate version/zone's maximum band weight, estimate the cost by **simulating a greedy weight-split into parcels** at that max, charging each parcel its own per-kg + handling fee, and summing. Orders at or under the max are unchanged. Flat (`zone = nil`) and zoned countries both supported. This is an interim estimate; once actual per-parcel costs exist, `effective_shipping_cost` already prefers `actual` and supersedes this.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Approach | **Split-parcel estimate (Option A)** — simulate parcels, sum per-parcel costs |
| Handling fee | **Per parcel** — each simulated parcel charges its band's `flat_fee_cny` (matches real split shipping) |
| Split rule | **Greedy by weight**: `floor(total / max)` full parcels at `max`, plus one remainder parcel if `remainder > 0`. Not item-aware (weight-only; sufficient for a budget estimate). |
| Trigger | Only when a single-band lookup for the total weight finds **no** band **and** `total > max band weight`. (Below-min / gap cases stay `nil`, as today.) |
| Max weight | The maximum `weight_max_kg` across the applicable version's rates **for the resolved zone**. |
| Uncovered fallback | If any simulated parcel's weight matches no band → return `nil` (uncovered), consistent with existing behavior. |
| Scope | Estimate only. No schema change. `actual_shipping_cost` (future) supersedes via `effective_shipping_cost`. |

## Behavior

In `ShippingCostCalculator`, the cost computation operates on the zone-scoped bands (`version.rates.where(zone: zone)`), loaded **once** into memory (no N+1 in the split loop).

```
bands       = zone-scoped rates (array)
band_for(w) = bands.find { |b| b.weight_min_kg < w && b.weight_max_kg >= w }

cost_cny(total):
  rate = band_for(total)
  return single_parcel(rate, total) if rate          # ≤ max & matches a band → unchanged

  max = bands.map(&:weight_max_kg).max
  return nil unless max && total > max                # below-min / gap / no bands → nil (unchanged)

  # split: greedy fill at max
  cny = 0
  remaining = total
  while remaining > max
    b = band_for(max); return nil unless b
    cny += single_parcel(b, max)
    remaining -= max
  end
  if remaining > 0
    b = band_for(remaining); return nil unless b
    cny += single_parcel(b, remaining)
  end
  cny

single_parcel(band, weight) = (weight * band.per_kg_rate_cny) + band.flat_fee_cny
```

Final: `(cost_cny / store.cost_fx_rate).round(2)` (unchanged). A full parcel at exactly `max` matches the top band (`weight_min < max AND weight_max >= max`).

### Worked example (the production case)
US, 6.3 kg, top band 0.5 kg gaps … max band `weight_max_kg = 5`. `band_for(6.3)` = nil; `6.3 > 5` → split:
- Parcel 1: 5 kg → top band → `5 × per_kg_top + flat_top`
- Parcel 2 (remainder): 1.3 kg → its band → `1.3 × per_kg_band + flat_band`
- `cost_cny = parcel1 + parcel2` (two handling fees) → `/ fx_rate` → estimate.

### Edge cases
- `total` ≤ max and matches a band → single parcel (current behavior, unchanged).
- `total` ≤ max but in a gap / below the lowest min → `nil` (unchanged).
- `total` > max but the version/zone has no bands → `nil`.
- `total` an exact multiple of `max` (e.g. 10 kg, max 5) → 2 full parcels, no remainder.
- A remainder parcel below the lowest band's min (e.g. lowest min 0.05, remainder 0.03) → `nil` (uncovered) — unlikely given real item weights, but defined.
- Zoned country: split uses that zone's bands (resolved zone unchanged); `:unmatched`/flat logic unchanged.

## Files

- Modify: `app/services/shipping_cost_calculator.rb` — replace the inline rate lookup + `cost_cny` with a `cost_cny_for(bands, weight_kg)` private method implementing the above (load bands once; in-memory `band_for`; greedy split). The `resolve_zone` step is unchanged.
- Test: `spec/services/shipping_cost_calculator_spec.rb` — extend.

No migration, model, controller, view, or i18n changes.

## Testing

`spec/services/shipping_cost_calculator_spec.rb` (extend):
- **Over-max splits (flat US):** bands up to 5 kg; 6.3 kg order → cost == `(5×pk_top + flat_top) + (1.3×pk_rem + flat_rem)` / fx; assert two handling fees are included (i.e., result equals the explicit two-parcel sum, not a single-parcel calc).
- **Exact multiple:** 10 kg, max 5 → 2 full parcels of 5 (cost == 2 × top-band parcel) / fx.
- **Three parcels:** 12 kg, max 5 → 5 + 5 + 2.
- **At/under max unchanged:** existing single-band examples still pass; an order at exactly `max` kg → single top-band parcel (no split).
- **Gap/below-min unchanged:** total in a gap or below lowest min → `nil` (not split).
- **Remainder below lowest min → nil.**
- **Zoned country over-max:** an AU zoned order over the zone's max → splits using that zone's bands.
- **No bands for the resolved zone → nil.**

## Out of scope
- Item-aware packing (we split by weight only).
- Actual per-parcel costs / parcel tracking numbers (separate future feature; will populate `actual_shipping_cost`).
- Per-carrier "max parcel weight" config separate from the rate card (we derive max from the bands).
