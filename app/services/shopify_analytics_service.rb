class ShopifyAnalyticsService
  def initialize(shop_domain:, access_token:, store_id:)
    @shop_domain = shop_domain
    @access_token = access_token
    @store_id = store_id
  end

  def sync_date(date)
    sessions_count = fetch_sessions(date)

    orders_data = Order.where(ordered_at: date.all_day)
    orders_count = orders_data.count
    revenue = orders_data.sum(:total_price)

    metric = ShopifyDailyMetric.find_or_initialize_by(
      shopify_store_id: @store_id, date: date
    )
    metric.assign_attributes(
      sessions: sessions_count,
      orders_count: orders_count,
      revenue: revenue,
      conversion_rate: sessions_count > 0 ? (orders_count.to_f / sessions_count) : 0
    )
    metric.save!
  end

  private

  def fetch_sessions(date)
    session = ShopifyAPI::Auth::Session.new(
      shop: @shop_domain,
      access_token: @access_token
    )
    client = ShopifyAPI::Clients::Graphql::Admin.new(session: session)

    query = <<~GQL
      {
        shopifyqlQuery(query: "FROM sessions SHOW count() WHERE day = '#{date.iso8601}' GROUP BY day SINCE #{date.iso8601} UNTIL #{date.iso8601}") {
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
  rescue => e
    Rails.logger.error("[ShopifyAnalytics] Failed to fetch sessions for #{date}: #{e.message}")
    0
  end
end
