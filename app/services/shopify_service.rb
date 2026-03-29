require "ostruct"

class ShopifyService
  BASE_URL_TEMPLATE = "https://%s/admin/api/2024-10"

  def initialize(shopify_store)
    @shop_domain = shopify_store.shop_domain
    @access_token = shopify_store.access_token
    @base_url = format(BASE_URL_TEMPLATE, @shop_domain)
  end

  # Backward-compatible class method for creating a service from ENV/credentials
  def self.from_env
    shop_domain = ENV["SHOPIFY_SHOP_DOMAIN"] || Rails.application.credentials.dig(:shopify, :shop_domain)
    access_token = ENV["SHOPIFY_ACCESS_TOKEN"] || Rails.application.credentials.dig(:shopify, :access_token)

    new(
      OpenStruct.new(shop_domain: shop_domain, access_token: access_token)
    )
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
