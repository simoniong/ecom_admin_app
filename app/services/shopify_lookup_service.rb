class ShopifyLookupService
  def initialize(shopify_service: nil)
    @shopify = shopify_service
  end

  def lookup(ticket)
    @store = ticket.email_account&.shopify_store
    shopify_service = resolve_shopify_service(ticket)
    return unless shopify_service

    customer = find_or_create_customer(shopify_service, ticket.customer_email)
    return unless customer

    ticket.update!(customer: customer)
    sync_orders(shopify_service, customer)
  end

  private

  def resolve_shopify_service(ticket)
    return @shopify if @shopify
    return nil unless @store

    ShopifyService.new(@store)
  end

  def find_or_create_customer(shopify_service, email)
    shopify_customers = shopify_service.find_customers_by_email(email)
    return nil if shopify_customers.empty?

    shopify_customer = shopify_customers.first

    # Use default_address for timezone — more reliably populated than per-order shipping_address
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

  def sync_orders(shopify_service, customer)
    shopify_orders = shopify_service.fetch_orders(customer.shopify_customer_id)

    shopify_orders.each do |shopify_order|
      attrs = {
        shopify_store: @store,
        email: shopify_order["email"],
        name: shopify_order["name"],
        total_price: shopify_order["total_price"],
        currency: shopify_order["currency"],
        financial_status: shopify_order["financial_status"],
        fulfillment_status: shopify_order["fulfillment_status"],
        ordered_at: shopify_order["created_at"],
        shopify_data: shopify_order
      }

      order = customer.orders.find_or_initialize_by(shopify_store: @store, shopify_order_id: shopify_order["id"])
      order.assign_attributes(attrs)
      begin
        order.save!
      rescue ActiveRecord::RecordNotUnique
        order = Order.find_by!(shopify_store: @store, shopify_order_id: shopify_order["id"])
        order.update!(attrs.merge(customer: customer))
      end

      sync_fulfillments(shopify_service, order)
    end
  end

  def sync_fulfillments(shopify_service, order)
    shopify_fulfillments = shopify_service.fetch_fulfillments(order.shopify_order_id)

    shopify_fulfillments.each do |sf|
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
      begin
        fulfillment.save!
      rescue ActiveRecord::RecordNotUnique
        order.fulfillments.find_by!(shopify_fulfillment_id: sf["id"]).update!(attrs)
      end
    end
  end
end
