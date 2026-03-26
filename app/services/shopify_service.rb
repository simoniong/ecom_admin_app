class ShopifyService
  BASE_URL_TEMPLATE = "https://%s/admin/api/2024-10"

  def initialize
    @shop_domain = Rails.application.credentials.dig(:shopify, :shop_domain)
    @access_token = Rails.application.credentials.dig(:shopify, :access_token)
    @base_url = format(BASE_URL_TEMPLATE, @shop_domain)
  end

  def find_customers_by_email(email)
    response = get("/customers/search.json", query: "email:#{email}")
    response["customers"] || []
  end

  def fetch_orders(shopify_customer_id, limit: 10)
    response = get("/customers/#{shopify_customer_id}/orders.json", status: "any", limit: limit)
    response["orders"] || []
  end

  def fetch_fulfillments(shopify_order_id)
    response = get("/orders/#{shopify_order_id}/fulfillments.json")
    response["fulfillments"] || []
  end

  private

  def get(path, **params)
    url = "#{@base_url}#{path}"
    response = HTTParty.get(url, query: params, headers: headers)
    raise "Shopify API error (#{response.code}): #{response.body}" unless response.success?
    response.parsed_response
  end

  def headers
    {
      "X-Shopify-Access-Token" => @access_token,
      "Content-Type" => "application/json"
    }
  end
end
