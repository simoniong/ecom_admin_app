# Per-parcel estimate comparison for one order's shipping-variance view.
#
# ShippingCostCalculator only knows how to price an ORDER (one weight, one
# zone, one number). This service reuses its resolved Basis (rate card
# version + zone + fx rate) to price each PARCEL's billed weight
# individually, so the order-level variance can be decomposed into:
#
#   實際 − 訂單預估 = 折包代價 (split_cost) + 物流商可能超收 (overcharge)
#
# where 折包代價 = Σ(per-parcel estimate) − 訂單預估 (the cost of splitting
# into N parcels — each pays its own flat/handling fee) and 物流商可能超收 =
# 實際 − Σ(per-parcel estimate) (what was actually billed vs. what the rate
# card says those parcels should cost).
#
# All money is computed in CNY (the parcels' native billing currency) and
# only converted to store currency for display, so the invariant above holds
# exactly without fx rounding creeping in.
class ParcelEstimateComparator
  ParcelLine = Struct.new(
    :parcel,
    :estimate_cny, :estimate,
    :actual_cny, :actual,
    :variance_cny, :variance, :variance_pct,
    :billed_zone, :zone_mismatch,
    keyword_init: true
  )

  Result = Struct.new(
    :order, :basis,
    :order_estimate_cny, :order_estimate,
    :estimated_zone, :zoned, :order_weight_kg,
    :parcel_lines,
    :parcels_estimate_cny, :decomposable,
    :billed_weight_total_kg,
    :actual_total_cny,
    :split_cost_cny, :overcharge_cny,
    :any_zone_mismatch,
    keyword_init: true
  )

  # `cache` is an optional Hash forwarded to ShippingCostCalculator.basis so
  # callers pricing many orders in one request (the /parcels index) can share
  # a single rate-card-version / postal-zone lookup cache across them. Left at
  # its default `{}`, behavior is unchanged from before this parameter existed.
  def initialize(order, cache: {})
    @order = order
    @cache = cache
  end

  def call
    basis = ShippingCostCalculator.basis(@order, cache: @cache)
    parcels = @order.parcels.to_a

    lines = parcels.map { |parcel| build_line(basis, parcel) }

    order_estimate_cny = basis&.order_estimate_cny
    parcels_estimate_cny = lines.filter_map(&:estimate_cny).sum

    # Decomposable only when EVERY parcel has an estimate (and there's at
    # least one parcel to decompose, and an order-level estimate to diff
    # against). If any parcel's estimate is nil (missing billed weight / no
    # matching band), Σ(per-parcel estimate) would silently undercount, and
    # the split/overcharge split would misattribute money that's actually
    # just "unknown" — so the UI must hide the decomposition instead of
    # showing a wrong number.
    decomposable = basis.present? && lines.present? && lines.none? { |line| line.estimate_cny.nil? }

    actual_total_cny = parcels.sum(&:cost_cny)

    if decomposable
      split_cost_cny  = parcels_estimate_cny - order_estimate_cny
      overcharge_cny  = actual_total_cny - parcels_estimate_cny
    end

    Result.new(
      order: @order,
      basis: basis,
      order_estimate_cny: order_estimate_cny,
      order_estimate: basis&.order_estimate,
      estimated_zone: basis&.zone,
      zoned: basis&.zoned || false,
      order_weight_kg: basis&.order_weight_kg,
      parcel_lines: lines,
      parcels_estimate_cny: parcels_estimate_cny,
      decomposable: decomposable,
      billed_weight_total_kg: billed_weight_total_kg(parcels),
      actual_total_cny: actual_total_cny,
      split_cost_cny: split_cost_cny,
      overcharge_cny: overcharge_cny,
      any_zone_mismatch: lines.any?(&:zone_mismatch)
    )
  end

  private

  def build_line(basis, parcel)
    estimate_cny = basis && parcel.billed_weight_g ? basis.estimate_cny_for(parcel.billed_weight_g / 1000.0) : nil
    estimate = estimate_cny && basis ? (estimate_cny / basis.fx_rate).round(2) : nil

    actual_cny = parcel.cost_cny
    actual = parcel.cost_amount

    variance_cny = estimate_cny ? actual_cny - estimate_cny : nil
    variance = (estimate && actual) ? actual - estimate : nil
    variance_pct = (estimate_cny && estimate_cny.nonzero?) ? (variance_cny / estimate_cny * 100).round(2) : nil

    estimated_zone = basis&.zone
    billed_zone = parcel.zone
    zone_mismatch = estimated_zone.present? && billed_zone.present? && estimated_zone.to_s != billed_zone.to_s

    ParcelLine.new(
      parcel: parcel,
      estimate_cny: estimate_cny, estimate: estimate,
      actual_cny: actual_cny, actual: actual,
      variance_cny: variance_cny, variance: variance, variance_pct: variance_pct,
      billed_zone: billed_zone, zone_mismatch: zone_mismatch
    )
  end

  # Sum of the billed weights we actually have, in kg. Parcels missing a
  # billed_weight_g are skipped (not treated as 0) — this total is a display
  # comparison against the order's estimated weight, not a money figure, so a
  # partial sum is acceptable as long as it's clearly a sum of what's known.
  def billed_weight_total_kg(parcels)
    grams = parcels.filter_map(&:billed_weight_g)
    return nil if grams.empty?
    grams.sum / 1000.0
  end
end
