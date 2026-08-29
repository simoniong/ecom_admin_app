class BackfillOrderLineItemsService
  def initialize(shopify_store)
    @store = shopify_store
    @processed = 0
    @snapshotted = 0
    @shipping_filled = 0
  end

  def call
    Rails.logger.info("[BackfillLineItems] start store=#{@store.shop_domain}")
    @store.orders.find_each(batch_size: 200) do |order|
      (order.shopify_data&.dig("line_items") || []).each { |li| upsert_line_item(order, li) }
      backfill_estimated_shipping(order)
      @processed += 1
    end
    Rails.logger.info("[BackfillLineItems] done orders=#{@processed} snapshotted=#{@snapshotted} shipping=#{@shipping_filled}")
    { orders: @processed, snapshotted: @snapshotted, shipping_filled: @shipping_filled }
  end

  private

  def upsert_line_item(order, li)
    variant = variant_lookup[li["variant_id"]]
    line_item = order.order_line_items.find_or_initialize_by(shopify_line_item_id: li["id"])
    line_item.assign_attributes(
      product_variant: variant,
      sku_at_sale: li["sku"],
      title_at_sale: li["title"],
      quantity: li["quantity"],
      unit_price: li["price"],
      currency: order.currency,
      shopify_data: li
    )
    # Same fulfilment gate as SyncAllOrdersService#apply_shipping_quantity: track
    # current_quantity while the order is unshipped, freeze it once fulfilled.
    if order.fulfillment_status == "fulfilled"
      line_item.quantity_snapshot ||= li["quantity"]
    else
      line_item.quantity_snapshot = li["current_quantity"] || li["quantity"]
    end

    # Snapshot the weight beside the cost, and for the same reason: both are
    # variant attributes the order's frozen money figures were computed from,
    # and both must survive a later edit to that variant. Set-once (nil check)
    # so a re-sync never overwrites the value the estimate was priced at.
    if line_item.weight_grams_snapshot.nil? && variant&.weight_grams&.positive?
      line_item.weight_grams_snapshot = variant.weight_grams
    end

    if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present? && @store.cost_fx_rate&.positive?
      # unit_cost + packaging_cost are in CNY; divide by CNY-per-store-currency rate.
      line_item.unit_cost_snapshot =
        (variant.unit_cost + variant.packaging_cost) / @store.cost_fx_rate
      @snapshotted += 1
    end
    line_item.save!
  end

  def backfill_estimated_shipping(order)
    return if order.estimated_shipping_cost.present?
    basis = ShippingCostCalculator.basis(order)
    cost = basis&.order_estimate
    return unless cost
    order.update!(estimated_shipping_cost: cost,
                  estimated_shipping_cost_cny: basis.order_estimate_cny)
    @shipping_filled += 1
  end

  def variant_lookup
    @variant_lookup ||= ProductVariant.joins(:product)
                                      .where(products: { shopify_store_id: @store.id })
                                      .index_by(&:shopify_variant_id)
  end
end
