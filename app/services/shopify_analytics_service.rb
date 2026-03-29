class ShopifyAnalyticsService
  def initialize(shop_domain:, access_token:, store_id:)
    @shop_domain = shop_domain
    @access_token = access_token
    @store_id = store_id
  end

  def sync_date(date)
    analytics = fetch_analytics(date)

    metric = ShopifyDailyMetric.find_or_initialize_by(
      shopify_store_id: @store_id, date: date
    )
    metric.assign_attributes(
      sessions: analytics[:sessions],
      orders_count: analytics[:orders],
      revenue: analytics[:revenue],
      conversion_rate: analytics[:sessions] > 0 ? (analytics[:orders].to_f / analytics[:sessions]) : 0
    )
    metric.save!
  end

  private

  def fetch_analytics(date)
    client = build_graphql_client

    sessions = fetch_shopifyql(client, "FROM sessions SHOW count() WHERE day = '#{date.iso8601}'")
    orders = fetch_shopifyql(client, "FROM orders SHOW count() WHERE order_date = '#{date.iso8601}'")
    revenue = fetch_shopifyql(client, "FROM orders SHOW sum(net_sales) WHERE order_date = '#{date.iso8601}'")

    { sessions: sessions, orders: orders, revenue: revenue.to_d }
  rescue => e
    Rails.logger.error("[ShopifyAnalytics] Failed to fetch analytics for #{date}: #{e.message}")
    { sessions: 0, orders: 0, revenue: 0 }
  end

  def build_graphql_client
    session = ShopifyAPI::Auth::Session.new(
      shop: @shop_domain,
      access_token: @access_token
    )
    ShopifyAPI::Clients::Graphql::Admin.new(session: session)
  end

  def fetch_shopifyql(client, shopifyql_query)
    query = <<~GQL
      {
        shopifyqlQuery(query: "#{shopifyql_query.gsub('"', '\\"')}") {
          __typename
          ... on TableResponse {
            tableData {
              rowData
              columns { name dataType }
            }
          }
        }
      }
    GQL

    response = client.query(query: query)
    data = response.body.dig("data", "shopifyqlQuery", "tableData", "rowData")
    return 0 if data.blank?
    data.first&.first.to_i
  end
end
