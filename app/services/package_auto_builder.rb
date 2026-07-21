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

    existing = @store.packages.find_by(order_id: @order.id)
    if fully_refunded?
      refund(existing) if existing
      return
    end
    return if existing
    return unless eligible?

    build_package
  end

  private

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

  def build_package
    number = next_number
    Package.transaction do
      package = @store.packages.create!(order: @order, number: number)
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

  # Row-locked sequence: continuous, no gaps.
  def next_number
    @store.with_lock do
      seq = @store.package_number_seq || @store.package_number_start
      @store.update!(package_number_seq: seq + 1)
      seq
    end
  end
end
