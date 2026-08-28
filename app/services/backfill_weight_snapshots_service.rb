# Fills order_line_items.weight_grams_snapshot for rows written before the
# column existed.
#
# The value copied in is the variant's weight TODAY, which is the best figure
# available — the weight each order was originally priced at was never
# recorded, and cannot be recovered. For orders whose SKUs have not been edited
# since (the common case) it is exactly right; for any that have, it pins the
# estimate to today's weight rather than the original one. Either way, from
# here on the value stops moving, which is the point.
#
# refresh: true overwrites snapshots that are already set. That is the escape
# hatch for a SKU whose recorded weight was simply wrong: correct the variant,
# refresh the snapshots, then re-run shipping:reestimate to re-baseline the
# affected orders deliberately rather than by accident.
class BackfillWeightSnapshotsService
  def initialize(refresh: false, store_ids: nil)
    @refresh = refresh
    @store_ids = store_ids
  end

  def call
    scanned = 0
    filled = 0
    skipped_no_weight = 0

    scope.includes(:product_variant).find_each(batch_size: 500) do |line_item|
      scanned += 1
      weight = line_item.product_variant&.weight_grams

      if weight.nil? || !weight.positive?
        skipped_no_weight += 1
        next
      end

      next if line_item.weight_grams_snapshot == weight

      # update_column: this backfills a denormalized figure and must not touch
      # updated_at or fire callbacks that would look like a real order edit.
      line_item.update_column(:weight_grams_snapshot, weight)
      filled += 1
    end

    { scanned: scanned, filled: filled, skipped_no_weight: skipped_no_weight, refresh: @refresh }
  end

  private

  def scope
    s = OrderLineItem.all
    s = s.where(weight_grams_snapshot: nil) unless @refresh
    s = s.joins(:order).where(orders: { shopify_store_id: @store_ids }) if @store_ids
    s
  end
end
