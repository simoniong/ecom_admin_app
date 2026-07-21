# Builds/refunds a Package for an order as it syncs. Called from
# SyncAllOrdersService#sync_order after the order is upserted.
class PackageAutoBuilder
  PAID_STATUSES = %w[paid partially_paid].freeze

  def initialize(order)
    @order = order
    @store = order.shopify_store
  end

  def call
    return unless @store&.packing_enabled?

    do_call
  rescue => e
    Rails.logger.error("[PackageAutoBuilder] Order##{@order.id} failed: #{e.class}: #{e.message}")
    nil
  end

  private

  def do_call
    existing = @store.packages.find_by(order_id: @order.id)
    if fully_refunded?
      refund(existing) if existing
      return
    end
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
    PAID_STATUSES.include?(@order.financial_status) && !cancelled?
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
      package = @store.packages.create!(order: @order, number: seq)
      @order.order_line_items.find_each do |li|
        package.package_items.create!(
          product_variant_id: li.product_variant_id,
          order_line_item_id: li.id,
          sku: li.sku_at_sale,
          title: li.title_at_sale,
          quantity: li.quantity
        )
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # A concurrent sync already built it; safe to ignore (order_id is unique).
    nil
  end
end
