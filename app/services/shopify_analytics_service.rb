class ShopifyAnalyticsService
  BASE_URL_TEMPLATE = "https://%s/admin/api/2024-10"

  def initialize(shop_domain:, access_token:, store_id:)
    @shop_domain = shop_domain
    @access_token = access_token
    @store_id = store_id
    @base_url = format(BASE_URL_TEMPLATE, @shop_domain)
  end

  def sync_date(date)
    orders_count = fetch_orders_count(date)
    revenue = fetch_revenue(date)

    metric = ShopifyDailyMetric.find_or_initialize_by(
      shopify_store_id: @store_id, date: date
    )
    metric.assign_attributes(
      sessions: 0, # ShopifyQL not available on this plan; sessions left at 0 for now
      orders_count: orders_count,
      revenue: revenue,
      conversion_rate: 0
    )
    metric.save!
  rescue => e
    Rails.logger.error("[ShopifyAnalytics] Failed to sync for #{date}: #{e.message}")
  end

  private

  def fetch_orders_count(date)
    response = get("/orders/count.json",
      status: "any",
      created_at_min: date.beginning_of_day.iso8601,
      created_at_max: date.end_of_day.iso8601)
    response["count"] || 0
  end

  def fetch_revenue(date)
    orders = get("/orders.json",
      status: "any",
      financial_status: "paid",
      created_at_min: date.beginning_of_day.iso8601,
      created_at_max: date.end_of_day.iso8601,
      fields: "total_price",
      limit: 250)
    (orders["orders"] || []).sum { |o| o["total_price"].to_d }
  end

  def get(path, **params)
    response = HTTParty.get(
      "#{@base_url}#{path}",
      query: params,
      headers: {
        "X-Shopify-Access-Token" => @access_token,
        "Content-Type" => "application/json"
      }
    )
    raise "Shopify API error (#{response.code}): #{response.body}" unless response.success?
    response.parsed_response
  end
end
