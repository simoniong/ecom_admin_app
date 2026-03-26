class ShopifyLookupService
  def initialize(shopify_service: ShopifyService.new)
    @shopify = shopify_service
  end

  def lookup(ticket)
    customer = find_or_create_customer(ticket.customer_email)
    return unless customer

    ticket.update!(customer: customer)
    sync_orders(customer)
  end

  private

  def find_or_create_customer(email)
    shopify_customers = @shopify.find_customers_by_email(email)
    return nil if shopify_customers.empty?

    shopify_customer = shopify_customers.first

    Customer.find_or_initialize_by(shopify_customer_id: shopify_customer["id"]).tap do |c|
      c.assign_attributes(
        email: shopify_customer["email"],
        first_name: shopify_customer["first_name"],
        last_name: shopify_customer["last_name"],
        phone: shopify_customer["phone"],
        shopify_data: shopify_customer
      )
      c.save!
    end
  end

  def sync_orders(customer)
    shopify_orders = @shopify.fetch_orders(customer.shopify_customer_id)

    shopify_orders.each do |shopify_order|
      order = customer.orders.find_or_initialize_by(shopify_order_id: shopify_order["id"])
      order.assign_attributes(
        email: shopify_order["email"],
        name: shopify_order["name"],
        total_price: shopify_order["total_price"],
        currency: shopify_order["currency"],
        financial_status: shopify_order["financial_status"],
        fulfillment_status: shopify_order["fulfillment_status"],
        ordered_at: shopify_order["created_at"],
        shopify_data: shopify_order
      )
      order.save!

      sync_fulfillments(order)
    end
  end

  def sync_fulfillments(order)
    shopify_fulfillments = @shopify.fetch_fulfillments(order.shopify_order_id)

    shopify_fulfillments.each do |sf|
      fulfillment = order.fulfillments.find_or_initialize_by(shopify_fulfillment_id: sf["id"])
      tracking = sf["tracking_numbers"]&.first
      fulfillment.assign_attributes(
        status: sf["status"],
        tracking_number: tracking || sf["tracking_number"],
        tracking_company: sf["tracking_company"],
        tracking_url: sf["tracking_url"] || sf["tracking_urls"]&.first,
        shopify_data: sf
      )
      fulfillment.save!
    end
  end
end
