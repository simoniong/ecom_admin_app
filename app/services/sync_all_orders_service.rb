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

    attrs = {
      customer: customer,
      email: shopify_order["email"],
      name: shopify_order["name"],
      total_price: shopify_order["total_price"],
      currency: shopify_order["currency"],
      financial_status: shopify_order["financial_status"],
      fulfillment_status: shopify_order["fulfillment_status"],
      ordered_at: shopify_order["created_at"],
      shopify_data: shopify_order
    }

    order = Order.find_or_initialize_by(shopify_order_id: shopify_order["id"])
    order.assign_attributes(attrs)
    begin
      order.save!
    rescue ActiveRecord::RecordNotUnique
      order = Order.find_by!(shopify_order_id: shopify_order["id"])
      order.update!(attrs)
    end

    sync_fulfillments(order, shopify_order)
    order
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

    customer = Customer.find_or_initialize_by(shopify_customer_id: shopify_customer["id"])
    customer.assign_attributes(attrs)
    customer.save!
    customer
  rescue ActiveRecord::RecordNotUnique
    Customer.find_by!(shopify_customer_id: shopify_customer["id"]).tap { |c| c.update!(attrs) }
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

  def upsert_fulfillment(order, sf)
    tracking = sf["tracking_numbers"]&.first
    attrs = {
      status: sf["status"],
      tracking_number: tracking || sf["tracking_number"],
      tracking_company: sf["tracking_company"],
      tracking_url: sf["tracking_url"] || sf["tracking_urls"]&.first,
      shopify_data: sf
    }

    fulfillment = order.fulfillments.find_or_initialize_by(shopify_fulfillment_id: sf["id"])
    fulfillment.assign_attributes(attrs)
    fulfillment.save!
  rescue ActiveRecord::RecordNotUnique
    order.fulfillments.find_by!(shopify_fulfillment_id: sf["id"]).update!(attrs)
  end
end
