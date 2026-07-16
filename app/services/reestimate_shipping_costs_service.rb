# Recomputes orders.estimated_shipping_cost against the CURRENT shipping rate
# cards and OVERWRITES the existing (frozen) value. This is the deliberate
# counterpart to BackfillOrderLineItemsService#backfill_estimated_shipping,
# which only fills blanks and never overwrites — this service exists so ops
# can refresh stale estimates after a rate card change (a new
# ShippingRateCardVersion with a later effective_from) without waiting for
# orders to re-sync.
#
# When the current estimate can't be computed (no matching rate card, no
# weight, no address, ...) the order is left untouched — we skip it rather
# than clearing out a previously-good value.
class ReestimateShippingCostsService
  # country: nil = all countries (matched via Order.with_destination_country,
  #   the same shipping-then-billing resolution ShippingCostCalculator uses).
  # from: nil = all dates; otherwise a Date/Time filtering on ordered_at >= from.
  # store_ids: nil = all stores.
  def initialize(country: nil, from: nil, store_ids: nil)
    @country = country
    @from = from
    @store_ids = store_ids
  end

  def call
    scanned = 0
    updated = 0
    skipped = 0
    cache = {}

    orders_scope.includes(order_line_items: :product_variant).find_each(batch_size: 200) do |order|
      scanned += 1
      estimate = ShippingCostCalculator.basis(order, cache: cache)&.order_estimate
      if estimate.nil?
        skipped += 1
        next
      end

      order.update_column(:estimated_shipping_cost, estimate)
      updated += 1
    end

    { scanned: scanned, updated: updated, skipped: skipped }
  end

  private

  def orders_scope
    scope = Order.all
    scope = scope.where(shopify_store_id: @store_ids) if @store_ids
    scope = scope.where("orders.ordered_at >= ?", @from) if @from
    scope = scope.with_destination_country(@country) if @country.present?
    scope
  end
end
