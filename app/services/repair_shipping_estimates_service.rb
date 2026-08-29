# Repairs frozen estimated_shipping_cost values whose divergence from the
# current recomputation can be PROVEN to come from a known cause.
#
# Two causes are known, and each has its own proof:
#
#   partial order   — before SyncAllOrdersService recomputed on line-item
#                     change, a post-purchase upsell left the estimate pricing
#                     only the goods in the first webhook payload. Proof: the
#                     first k line items, by created_at, reprice to the frozen
#                     value exactly.
#
#   operation fee   — the ¥2 per-parcel handling fee was folded into the
#                     estimate on 2026-07-17 so an on-target order would read
#                     ~¥0 variance instead of a standing phantom overcharge.
#                     Estimates frozen before that never got it. Proof: the
#                     current estimate minus n of those fees reprices to the
#                     frozen value exactly.
#
# An exact match is what makes either a proof: had anything else moved (a SKU
# weight, the rate card, the fx rate) the equality could not hold. Orders that
# prove nothing are reported and left alone — a repair must never quietly
# reprice an order it cannot explain.
#
# The two proofs write the SAME value (the current full estimate); they differ
# only in the reason reported. So even where both could match, attribution is
# cosmetic and the write is identical.
class RepairShippingEstimatesService
  # An order split into more parcels than this is not something the greedy
  # split produces in practice; the bound just stops the search running away.
  MAX_OPERATION_FEES = 10

  Repair = Struct.new(:order_id, :order_name, :frozen, :repaired, :repaired_cny,
                      :proof, :detail, keyword_init: true)

  Unexplained = Struct.new(:order_id, :order_name, :frozen, :recomputed, keyword_init: true)

  def initialize(apply: false, store_ids: nil, from: nil)
    @apply = apply
    @store_ids = store_ids
    @from = from
  end

  def call
    scanned = 0
    repairs = []
    unexplained = []
    cache = {}

    orders_scope.includes(:shopify_store, order_line_items: :product_variant)
                .find_each(batch_size: 200) do |order|
      scanned += 1

      items = order.order_line_items.sort_by { |li| [ li.created_at, li.id ] }
      next if items.empty?
      # A missing weight makes every figure below nil; nothing to prove.
      next unless items.all? { |li| li.shipping_weight_grams&.positive? }

      basis = ShippingCostCalculator.basis(order, cache: cache)
      next unless basis

      frozen = order.estimated_shipping_cost
      full_weight = weight_kg(items)
      full_cny = basis.estimate_cny_for(full_weight)
      next if full_cny.nil?

      full_estimate = (full_cny / basis.fx_rate).round(2)
      next if full_estimate == frozen

      repair = prove(basis, items, full_cny, frozen) do |proof, detail|
        Repair.new(order_id: order.id, order_name: order.name,
                   frozen: frozen, repaired: full_estimate, repaired_cny: full_cny,
                   proof: proof, detail: detail)
      end

      if repair.nil?
        unexplained << Unexplained.new(order_id: order.id, order_name: order.name,
                                       frozen: frozen, recomputed: full_estimate)
        next
      end

      repairs << repair

      # update_columns, not update!: this corrects denormalized figures and must
      # not fire callbacks or move updated_at, the same reason
      # ReestimateShippingCostsService uses it.
      if @apply
        order.update_columns(estimated_shipping_cost: full_estimate,
                             estimated_shipping_cost_cny: full_cny)
      end
    end

    { scanned: scanned, applied: @apply, repairs: repairs, unexplained: unexplained }
  end

  private

  # Tries the more specific proof first. Both yield the same repaired value, so
  # the order only decides which reason is reported.
  def prove(basis, items, full_cny, frozen)
    if (k = proven_prefix_size(basis, items, frozen))
      return yield(:partial_order, "priced #{k}/#{items.size} items " \
                                   "(#{format('%.3f', weight_kg(items.first(k)))} kg " \
                                   "of #{format('%.3f', weight_kg(items))} kg)")
    end

    if (n = proven_missing_operation_fees(basis, full_cny, frozen))
      return yield(:operation_fee, "missing #{n} × ¥#{ShippingCostCalculator::OPERATION_FEE_CNY.to_i} " \
                                   "handling fee#{'s' if n > 1}")
    end

    nil
  end

  # The number of leading line items whose combined weight reproduces the frozen
  # estimate exactly, or nil. Only proper prefixes are tried: a full-length match
  # would mean the estimate is already correct, which the caller has ruled out.
  # A single-item order has no proper prefix, so this proof never applies to one.
  def proven_prefix_size(basis, items, frozen)
    (1...items.size).find do |k|
      estimate_for(basis, weight_kg(items.first(k))) == frozen
    end
  end

  # How many per-parcel handling fees the frozen figure is short, or nil. Priced
  # in CNY and converted once, mirroring Basis#order_estimate, so the comparison
  # is against the same rounding the frozen value went through.
  def proven_missing_operation_fees(basis, full_cny, frozen)
    (1..MAX_OPERATION_FEES).find do |n|
      shortfall = full_cny - (ShippingCostCalculator::OPERATION_FEE_CNY * n)
      shortfall.positive? && (shortfall / basis.fx_rate).round(2) == frozen
    end
  end

  def weight_kg(items)
    items.sum { |li| li.shipping_weight_grams * li.quantity } / 1000.0
  end

  def estimate_for(basis, weight_kg)
    cny = basis.estimate_cny_for(weight_kg)
    return nil unless cny
    (cny / basis.fx_rate).round(2)
  end

  def orders_scope
    scope = Order.where.not(estimated_shipping_cost: nil)
    scope = scope.where(shopify_store_id: @store_ids) if @store_ids
    scope = scope.where("orders.ordered_at >= ?", @from) if @from
    scope
  end
end
