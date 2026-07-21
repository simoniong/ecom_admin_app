# Builds/refunds a Package for an order as it syncs. Called from
# SyncAllOrdersService#sync_order after the order is upserted.
class PackageAutoBuilder
  PAID_STATUSES = %w[paid partially_paid].freeze

  def initialize(order)
    @order = order
    @store = order.shopify_store
  end

  def call
    do_call
  rescue => e
    Rails.logger.error("[PackageAutoBuilder] Order##{@order.id} failed: #{e.class}: #{e.message}")
    nil
  end

  private

  # Refund of an EXISTING package must run regardless of packing_enabled? —
  # a store that has since turned packing off (or a package built before it
  # was disabled) must still see that package transition to refunded on a
  # full refund. packing_enabled? gates ONLY new-package creation below.
  def do_call
    return unless @store

    existing = @store.packages.find_by(order_id: @order.id)
    if fully_refunded?
      refund(existing) if existing
      return
    end
    return unless @store.packing_enabled?
    return if existing
    return unless eligible?

    build_package
  end

  def fully_refunded?
    @order.financial_status == "refunded"
  end

  def cancelled?
    @order.shopify_data["cancelled_at"].present?
  end

  def eligible?
    PAID_STATUSES.include?(@order.financial_status) && !cancelled? && not_backfill?
  end

  # No-backfill guard: only build packages for orders placed at/after the
  # moment packing was switched on for this store. Without this, enabling
  # packing on an already-synced store would build packages for the store's
  # entire eligible order history on the next sync (see design doc: "只對開關
  # 打開後、新同步進來的訂單建包裹...不回溯既有舊訂單;歷史 backfill 是 Phase 4").
  # Deliberately NOT applied to the refund path (fully_refunded? in do_call) —
  # a refund on any existing package, however old, must still transition it.
  def not_backfill?
    @store.packing_enabled_at.present? &&
      @order.ordered_at.present? &&
      @order.ordered_at >= @store.packing_enabled_at
  end

  def refund(package)
    package.refund! unless package.refunded?
  end

  # Existence re-check, number assignment, and package+items creation all
  # happen inside a single row lock so concurrent syncs of the SAME order
  # serialize: the second process, after acquiring the lock, sees the
  # package the first created and bails WITHOUT consuming a sequence number
  # (continuous, no gaps).
  def build_package
    @store.with_lock do
      return if @store.packages.exists?(order_id: @order.id)

      seq = @store.package_number_seq || @store.package_number_start
      @store.update!(package_number_seq: seq + 1)
      package = @store.packages.create!(
        order: @order,
        number: seq,
        shipping_address_snapshot: @order.shopify_data["shipping_address"] || {}
      )
      refunds = refunded_quantities # { shopify_line_item_id => qty }
      @order.order_line_items.find_each do |li|
        package.package_items.create!(
          customs_attributes_for(li).merge(
            product_variant_id: li.product_variant_id,
            order_line_item_id: li.id,
            sku: li.sku_at_sale,
            title: li.title_at_sale,
            quantity: li.quantity,
            refunded_quantity: refunds[li.shopify_line_item_id] || 0
          )
        )
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # A concurrent sync already built it; safe to ignore (order_id is unique).
    nil
  end

  # Customs snapshot copied from the line item's product_variant (nil-safe).
  def customs_attributes_for(line_item)
    v = line_item.product_variant
    return {} unless v

    {
      customs_name_zh: v.customs_name_zh,
      customs_name_en: v.customs_name_en,
      declared_value_usd: v.declared_value_usd,
      hs_code: v.hs_code,
      import_hs_code: v.import_hs_code,
      customs_weight_grams: v.weight_grams
    }
  end

  # Sum of refunded/cancelled units per shopify_line_item_id, from the order's
  # Shopify payload. { shopify_line_item_id (Integer) => refunded_qty (Integer) }
  def refunded_quantities
    result = Hash.new(0)
    Array(@order.shopify_data["refunds"]).each do |refund|
      Array(refund["refund_line_items"]).each do |rli|
        lid = rli["line_item_id"]
        result[lid] += rli["quantity"].to_i if lid
      end
    end
    result
  end
end
