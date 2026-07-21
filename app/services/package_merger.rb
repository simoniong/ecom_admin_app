# Collapses a split order's pending_process sibling packages back into the
# lowest-numbered one (the original). Items are summed by order_line_item_id;
# package-level fields (address/logistics/note/customs) are the survivor's.
# See docs/superpowers/specs/2026-07-21-order-packing-phase2b3-split-merge-design.md.
class PackageMerger
  def initialize(package_or_order)
    @order = package_or_order.is_a?(Package) ? package_or_order.order : package_or_order
    @store = @order.shopify_store
  end

  def pending_siblings
    @store.packages.where(order_id: @order.id, aasm_state: "pending_process").order(:number).to_a
  end

  # True when the boxes to be merged disagree on address or logistics channel —
  # the UI warns before discarding the non-survivor values.
  def conflict?
    boxes = pending_siblings
    return false if boxes.size < 2

    boxes.map(&:shipping_address_snapshot).uniq.size > 1 ||
      boxes.map(&:logistics_channel_id).uniq.size > 1
  end

  # Returns the survivor package. A no-op (returns the lone box) when there is
  # nothing to merge.
  def call
    boxes = pending_siblings
    survivor = boxes.first
    return survivor if boxes.size < 2

    survivor.with_lock do
      boxes.drop(1).each { |box| absorb(box, survivor) }
    end
    survivor
  end

  private

  def absorb(box, survivor)
    # Reload once per absorbed sibling: a prior sibling in this same #call may
    # have just reassigned an item onto the survivor (package_id: survivor.id)
    # without appending it to the in-memory `survivor.package_items` collection,
    # which would otherwise go stale across iterations.
    survivor_items = survivor.package_items.reload.to_a
    box.package_items.to_a.each do |item|
      existing = survivor_items.find { |s| s.order_line_item_id == item.order_line_item_id }
      if existing
        existing.update!(
          quantity: existing.quantity + item.quantity,
          refunded_quantity: existing.refunded_quantity + item.refunded_quantity
        )
      else
        item.update!(package_id: survivor.id)
      end
    end
    box.reload.destroy!
  end
end
