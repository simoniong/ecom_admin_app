class BackfillOrderLineItemsService
  def initialize(shopify_store)
    @store = shopify_store
    @processed = 0
    @snapshotted = 0
  end

  def call
    Rails.logger.info("[BackfillLineItems] start store=#{@store.shop_domain}")
    @store.orders.find_each(batch_size: 200) do |order|
      (order.shopify_data&.dig("line_items") || []).each { |li| upsert_line_item(order, li) }
      @processed += 1
    end
    Rails.logger.info("[BackfillLineItems] done orders=#{@processed} snapshotted=#{@snapshotted}")
    { orders: @processed, snapshotted: @snapshotted }
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
    if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present? && @store.cost_fx_rate&.positive?
      # variant.unit_cost is in CNY; divide by CNY-per-store-currency rate.
      line_item.unit_cost_snapshot = variant.unit_cost / @store.cost_fx_rate
      @snapshotted += 1
    end
    line_item.save!
  end

  def variant_lookup
    @variant_lookup ||= ProductVariant.joins(:product)
                                      .where(products: { shopify_store_id: @store.id })
                                      .index_by(&:shopify_variant_id)
  end
end
