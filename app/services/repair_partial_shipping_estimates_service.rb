# Repairs orders whose frozen estimated_shipping_cost was computed against only
# PART of the order.
#
# Before the fix in SyncAllOrdersService, sync_estimated_shipping_cost returned
# early whenever an order already had an estimate. A post-purchase upsell (Loox,
# Shopify order edit) appends line items in a later webhook, so any order edited
# after its first sync kept an estimate that priced only the goods present in
# that first payload — always too low, because the appended weight was never
# counted.
#
# Overwriting every divergent order with today's recomputation would be the
# wrong repair: an estimate can also diverge because a SKU weight, a rate card
# or the store's fx rate moved since the order, and rewriting those would
# replace a historical cost with today's numbers.
#
# So each repair proves itself first. Line items are ordered by created_at and
# priced cumulatively; if the first k of them reproduce the frozen value
# EXACTLY, the frozen estimate is demonstrably a partial-order estimate — and,
# because the match is exact, nothing else (weights, rate card, fx) can have
# drifted either, since any drift would break the equality. Only then is the
# full-order estimate written. Orders that prove nothing are reported and left
# untouched for a human to look at.
class RepairPartialShippingEstimatesService
  Repair = Struct.new(:order_id, :order_name, :frozen, :repaired, :proven_item_count,
                      :total_item_count, :proven_weight_kg, :full_weight_kg, keyword_init: true)

  Unexplained = Struct.new(:order_id, :order_name, :frozen, :recomputed, keyword_init: true)

  # apply: false (the default) computes and reports without writing anything.
  # store_ids / from narrow the scan the same way ReestimateShippingCostsService
  # does, so a repair can be rehearsed on one store before it runs everywhere.
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

    orders_scope.includes(order_line_items: :product_variant).find_each(batch_size: 200) do |order|
      scanned += 1

      items = order.order_line_items.sort_by { |li| [ li.created_at, li.id ] }
      next if items.size < 2
      # A missing weight makes every figure below nil; nothing to prove or repair.
      next unless items.all? { |li| li.product_variant&.weight_grams&.positive? }

      basis = ShippingCostCalculator.basis(order, cache: cache)
      next unless basis

      frozen = order.estimated_shipping_cost
      full_weight = weight_kg(items)
      full_estimate = estimate_for(basis, full_weight)
      next if full_estimate.nil? || full_estimate == frozen

      proven = proven_prefix_size(basis, items, frozen)

      if proven.nil?
        unexplained << Unexplained.new(order_id: order.id, order_name: order.name,
                                       frozen: frozen, recomputed: full_estimate)
        next
      end

      repairs << Repair.new(
        order_id: order.id, order_name: order.name,
        frozen: frozen, repaired: full_estimate,
        proven_item_count: proven, total_item_count: items.size,
        proven_weight_kg: weight_kg(items.first(proven)), full_weight_kg: full_weight
      )

      # update_column, not update!: this corrects a denormalized figure and must
      # not fire callbacks or touch updated_at-driven sync logic — the same call
      # ReestimateShippingCostsService uses for the same reason.
      order.update_column(:estimated_shipping_cost, full_estimate) if @apply
    end

    { scanned: scanned, applied: @apply, repairs: repairs, unexplained: unexplained }
  end

  private

  # The number of leading line items whose combined weight reproduces the frozen
  # estimate exactly, or nil when no prefix does. Only proper prefixes are
  # tried: a full-length match would mean the estimate is already correct, which
  # the caller has ruled out.
  def proven_prefix_size(basis, items, frozen)
    (1...items.size).find do |k|
      estimate_for(basis, weight_kg(items.first(k))) == frozen
    end
  end

  def weight_kg(items)
    items.sum { |li| li.product_variant.weight_grams * li.quantity } / 1000.0
  end

  # Mirrors Basis#order_estimate exactly (CNY priced, then converted and rounded
  # once) so a comparison against the stored value is like-for-like.
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
