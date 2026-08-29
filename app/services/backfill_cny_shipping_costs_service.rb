# Fills orders.estimated_shipping_cost_cny / actual_shipping_cost_cny for rows
# written before those columns existed.
#
# The two sides are backfilled on different terms, because only one of them can
# be recovered exactly:
#
#   actual   — the parcels still carry their CNY billing amounts, so the total
#              is the carrier's own figure. Copied straight in.
#
#   estimate — the CNY the estimate was originally priced at was never stored.
#              Recomputing it is only safe when the recomputation still lands on
#              the SAME store-currency value that is frozen on the order: that
#              exact agreement proves nothing (weights, rate card, fx) has moved
#              since, so its CNY is the figure that was rounded to produce the
#              frozen one. When they disagree, the order is left converting at
#              the current rate exactly as it does today — a divergent order
#              must not be quietly repriced by a backfill.
class BackfillCnyShippingCostsService
  def initialize(apply: false, store_ids: nil)
    @apply = apply
    @store_ids = store_ids
  end

  def call
    scanned = 0
    actual_filled = 0
    estimate_proven = 0
    estimate_converted = 0
    estimate_unavailable = 0
    cache = {}

    scope.includes(:shopify_store, :parcels, order_line_items: :product_variant)
         .find_each(batch_size: 200) do |order|
      scanned += 1
      updates = {}

      if order.actual_shipping_cost_cny.nil? && order.parcels.any?
        updates[:actual_shipping_cost_cny] = order.parcels.sum(&:cost_cny)
        actual_filled += 1
      end

      if order.estimated_shipping_cost_cny.nil? && order.estimated_shipping_cost
        basis = ShippingCostCalculator.basis(order, cache: cache)

        if basis && basis.order_estimate == order.estimated_shipping_cost
          updates[:estimated_shipping_cost_cny] = basis.order_estimate_cny
          estimate_proven += 1
        elsif (converted = convert(order))
          updates[:estimated_shipping_cost_cny] = converted
          estimate_converted += 1
        else
          estimate_unavailable += 1
        end
      end

      next if updates.empty?

      order.update_columns(updates) if @apply
    end

    {
      scanned: scanned, applied: @apply,
      actual_filled: actual_filled,
      estimate_proven: estimate_proven,
      estimate_converted: estimate_converted,
      estimate_unavailable: estimate_unavailable
    }
  end

  private

  # Exactly what the order row renders today, so a converted backfill changes
  # no number on screen — it only stops the conversion happening per request.
  def convert(order)
    fx = order.shopify_store&.cost_fx_rate
    return nil unless fx&.positive?
    (order.estimated_shipping_cost * fx).round(2)
  end

  def scope
    s = Order.where(estimated_shipping_cost_cny: nil).or(Order.where(actual_shipping_cost_cny: nil))
    s = s.where(shopify_store_id: @store_ids) if @store_ids
    s
  end
end
