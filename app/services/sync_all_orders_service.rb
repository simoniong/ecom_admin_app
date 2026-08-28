class SyncAllOrdersService
  def initialize(shopify_store)
    @store = shopify_store
    @shopify = ShopifyService.new(shopify_store)
    @synced_orders = 0
    @synced_customers = 0
  end

  def call(incremental: false)
    updated_since = incremental && @store.orders_synced_at ? @store.orders_synced_at : nil
    mode = updated_since ? "incremental since #{updated_since}" : "full"
    Rails.logger.info("[SyncAllOrders] Starting for store=#{@store.shop_domain} mode=#{mode}")

    sync_started_at = Time.current

    sync_all_customers(updated_at_min: updated_since)
    sync_all_orders(updated_at_min: updated_since)

    link_orphaned_tickets

    @store.update!(orders_synced_at: sync_started_at)

    Rails.logger.info("[SyncAllOrders] Completed for store=#{@store.shop_domain}: #{@synced_customers} customers, #{@synced_orders} orders")

    { customers: @synced_customers, orders: @synced_orders }
  end

  def sync_single_order(shopify_order)
    sync_order(shopify_order)
  end

  private

  def sync_all_customers(updated_at_min: nil)
    since_id = nil

    loop do
      batch = @shopify.fetch_all_customers(since_id: since_id, updated_at_min: updated_at_min)
      break if batch.empty?

      batch.each do |shopify_customer|
        upsert_customer(shopify_customer)
        @synced_customers += 1
      end

      since_id = batch.last["id"]
      break if batch.size < 250
    end
  end

  def sync_all_orders(updated_at_min: nil)
    since_id = nil

    loop do
      batch = @shopify.fetch_all_orders(since_id: since_id, updated_at_min: updated_at_min)
      break if batch.empty?

      batch.each do |shopify_order|
        @synced_orders += 1 if sync_order(shopify_order)
      rescue => e
        Rails.logger.error("[SyncAllOrders] Failed to sync order #{shopify_order['id']}: #{e.message}")
      end

      since_id = batch.last["id"]
      break if batch.size < 250
    end
  end

  def sync_order(shopify_order)
    customer = resolve_customer(shopify_order)
    return unless customer

    # Prefer shop_money amounts so totals are always in the store's currency
    # even when the customer paid in a different presentment currency
    # (Shopify Markets). Falls back to the top-level field for older payloads.
    shop_total = shopify_order.dig("current_total_price_set", "shop_money", "amount") ||
                 shopify_order.dig("total_price_set", "shop_money", "amount") ||
                 shopify_order["total_price"]
    shop_currency = shopify_order.dig("current_total_price_set", "shop_money", "currency_code") ||
                    shopify_order.dig("total_price_set", "shop_money", "currency_code") ||
                    shopify_order["currency"]

    attrs = {
      customer: customer,
      shopify_store: @store,
      email: shopify_order["email"],
      name: shopify_order["name"],
      total_price: shop_total,
      currency: shop_currency,
      financial_status: shopify_order["financial_status"],
      fulfillment_status: shopify_order["fulfillment_status"],
      ordered_at: shopify_order["created_at"],
      paid_at: shopify_order["processed_at"],
      shopify_data: shopify_order
    }

    order = Order.find_or_initialize_by(shopify_store: @store, shopify_order_id: shopify_order["id"])
    is_new_order = order.new_record?
    old_fulfillment_status = order.fulfillment_status
    order.assign_attributes(attrs)
    begin
      order.save!
    rescue ActiveRecord::RecordNotUnique
      order = Order.find_by!(shopify_store: @store, shopify_order_id: shopify_order["id"])
      is_new_order = false
      old_fulfillment_status = order.fulfillment_status
      order.update!(attrs)
    end

    weight_changed = sync_line_items(order, shopify_order)
    PackageAutoBuilder.new(order).call
    sync_estimated_shipping_cost(order, recompute: weight_changed)
    sync_fulfillments(order, shopify_order)

    trigger_email_workflows(order, is_new_order, old_fulfillment_status)

    order
  end

  # Returns true when this sync added a line item, or moved an existing one's
  # quantity or variant — i.e. when the order's total shipping weight can have
  # changed. A re-sync that only churns prices, discounts or fulfilment status
  # must report false: recomputing the estimate on that noise would silently
  # reprice every order against today's variant weights and rate card.
  def sync_line_items(order, shopify_order)
    weight_changed = false

    (shopify_order["line_items"] || []).each do |li|
      variant = variant_lookup[li["variant_id"]]

      # Use shop_money so unit_price and currency match the order's store
      # currency (same as where cost_fx_rate converts cost to). Falls back to
      # presentment fields if shop_money is absent (older payloads).
      shop_price = li.dig("price_set", "shop_money", "amount") || li["price"]
      shop_currency = li.dig("price_set", "shop_money", "currency_code") || order.currency

      line_item = order.order_line_items.find_or_initialize_by(shopify_line_item_id: li["id"])
      line_item.assign_attributes(
        product_variant: variant,
        sku_at_sale: li["sku"],
        title_at_sale: li["title"],
        quantity: li["quantity"],
        unit_price: shop_price,
        currency: shop_currency,
        shopify_data: li
      )

      # Checked after assign_attributes and before save! — this is the only
      # point where the incoming payload and the stored row can be compared.
      weight_changed ||= line_item.new_record? ||
                         line_item.will_save_change_to_quantity? ||
                         line_item.will_save_change_to_product_variant_id?

      # Snapshot the weight beside the cost, and for the same reason: both are
      # variant attributes the order's frozen money figures were computed from,
      # and both must survive a later edit to that variant. Set-once (nil check)
      # so a re-sync never overwrites the value the estimate was priced at.
      if line_item.weight_grams_snapshot.nil? && variant&.weight_grams&.positive?
        line_item.weight_grams_snapshot = variant.weight_grams
      end

      if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present? && @store.cost_fx_rate&.positive?
        # unit_cost + packaging_cost are in CNY; divide by CNY-per-store-currency rate.
        # Snapshot is always in store currency (matches shop_money above).
        line_item.unit_cost_snapshot =
          (variant.unit_cost + variant.packaging_cost) / @store.cost_fx_rate
      end

      line_item.save!
    end

    weight_changed
  end

  # The estimate is frozen once set so the variance report compares actuals
  # against the price quoted for the order, not a moving target that drifts
  # every time a SKU weight or rate card is edited.
  #
  # But the ORDER itself still changes after that first sync: a post-purchase
  # upsell (Loox, Shopify order edit) appends line items seconds to minutes
  # later, arriving as a second webhook. Freezing unconditionally priced only
  # the goods that happened to be in the first payload — production order
  # PKS#4113 froze at 0.81 kg / $14.56 seventeen seconds before its upsell item
  # landed, and the variance report then read a $5 overrun that never happened.
  # The estimate has to follow the goods it is pricing, so `recompute` reopens
  # it for exactly the syncs that moved the order's weight.
  def sync_estimated_shipping_cost(order, recompute: false)
    return if order.estimated_shipping_cost.present? && !recompute

    # The line-item set was just written through the association; drop any
    # cached target so the calculator weighs the order as it now stands.
    order.order_line_items.reset

    # Resolve the Basis rather than calling .estimate: it carries the CNY the
    # rate card actually priced, which is stored alongside the store-currency
    # figure so no display has to convert back and lose a cent.
    basis = ShippingCostCalculator.basis(order)
    cost = basis&.order_estimate
    return unless cost

    order.update!(estimated_shipping_cost: cost,
                  estimated_shipping_cost_cny: basis.order_estimate_cny)
  end

  def variant_lookup
    @variant_lookup ||= ProductVariant.joins(:product)
                                      .where(products: { shopify_store_id: @store.id })
                                      .index_by(&:shopify_variant_id)
  end

  def resolve_customer(shopify_order)
    shopify_customer = shopify_order["customer"]
    return nil unless shopify_customer && shopify_customer["id"]

    upsert_customer(shopify_customer)
  end

  def upsert_customer(shopify_customer)
    country_code = shopify_customer.dig("default_address", "country_code")
    attrs = {
      email: shopify_customer["email"],
      first_name: shopify_customer["first_name"],
      last_name: shopify_customer["last_name"],
      phone: shopify_customer["phone"],
      timezone: TimezoneResolver.resolve(country_code),
      shopify_data: shopify_customer
    }

    customer = Customer.find_or_initialize_by(shopify_store: @store, shopify_customer_id: shopify_customer["id"])
    customer.assign_attributes(attrs)
    customer.save!
    customer
  rescue ActiveRecord::RecordNotUnique
    Customer.find_by!(shopify_store: @store, shopify_customer_id: shopify_customer["id"]).tap { |c| c.update!(attrs) }
  end

  def sync_fulfillments(order, shopify_order)
    shopify_fulfillments = shopify_order["fulfillments"] || []

    if shopify_fulfillments.any?
      shopify_fulfillments.each { |sf| upsert_fulfillment(order, sf) }
    else
      fetched = @shopify.fetch_fulfillments(order.shopify_order_id)
      fetched.each { |sf| upsert_fulfillment(order, sf) }
    end
  end

  def link_orphaned_tickets
    email_accounts = EmailAccount.where(shopify_store: @store)
    return if email_accounts.empty?

    orphaned_tickets = Ticket.where(email_account: email_accounts, customer_id: nil)
                             .where.not(customer_email: [ nil, "", "unknown" ])
                             .where("customer_email LIKE '%@%'")
    return if orphaned_tickets.empty?

    emails = orphaned_tickets.distinct.pluck(:customer_email).map(&:downcase)
    customers_by_email = @store.customers.where("LOWER(email) IN (?)", emails).index_by { |c| c.email&.downcase }

    orphaned_tickets.find_each do |ticket|
      customer = customers_by_email[ticket.customer_email.downcase]
      next unless customer

      ticket.update!(customer: customer)
      Rails.logger.info("[SyncAllOrders] Linked Ticket##{ticket.id} to Customer##{customer.id}")
    end
  end

  def trigger_email_workflows(order, is_new_order, old_fulfillment_status)
    EmailWorkflowTriggerService.check("order_placed", order) if is_new_order
    if old_fulfillment_status != "fulfilled" && order.fulfillment_status == "fulfilled"
      EmailWorkflowTriggerService.check("order_shipped", order)
    end
  rescue => e
    Rails.logger.error("[SyncAllOrders] Email workflow trigger failed for order #{order.id}: #{e.message}")
  end

  def upsert_fulfillment(order, sf)
    tracking = sf["tracking_numbers"]&.first
    attrs = {
      order: order,
      status: sf["status"],
      tracking_number: tracking || sf["tracking_number"],
      tracking_company: sf["tracking_company"],
      tracking_url: sf["tracking_url"] || sf["tracking_urls"]&.first,
      shopify_data: sf
    }

    fulfillment = Fulfillment.find_or_initialize_by(shopify_fulfillment_id: sf["id"])
    fulfillment.assign_attributes(attrs)
    fulfillment.save!
  rescue ActiveRecord::RecordNotUnique
    Fulfillment.find_by!(shopify_fulfillment_id: sf["id"]).update!(attrs)
  end
end
