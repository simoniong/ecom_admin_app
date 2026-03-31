class ShopifyAnalyticsService
  BASE_URL_TEMPLATE = "https://%s/admin/api/2024-10"

  def initialize(shop_domain:, access_token:, store_id:, timezone: "UTC")
    @shop_domain = shop_domain
    @access_token = access_token
    @store_id = store_id
    @timezone = ActiveSupport::TimeZone[timezone] || ActiveSupport::TimeZone["UTC"]
    @base_url = format(BASE_URL_TEMPLATE, @shop_domain)
  end

  def sync_date(date)
    orders_count = fetch_orders_count(date)
    gross_revenue = fetch_gross_revenue(date)
    refunds_total = fetch_refunds_total_via_graphql(date)

    metric = ShopifyDailyMetric.find_or_initialize_by(
      shopify_store_id: @store_id, date: date
    )
    metric.assign_attributes(
      sessions: 0,
      orders_count: orders_count,
      revenue: gross_revenue - refunds_total,
      conversion_rate: 0
    )
    metric.save!
  rescue => e
    Rails.logger.error("[ShopifyAnalytics] Failed to sync for #{date}: #{e.message}")
  end

  private

  def date_range_in_shop_timezone(date)
    start_time = @timezone.parse(date.to_s).beginning_of_day
    end_time = @timezone.parse(date.to_s).end_of_day
    [ start_time.iso8601, end_time.iso8601 ]
  end

  def fetch_orders_count(date)
    min, max = date_range_in_shop_timezone(date)
    response = rest_get("/orders/count.json",
      status: "any",
      created_at_min: min,
      created_at_max: max)
    response["count"] || 0
  end

  def fetch_gross_revenue(date)
    min, max = date_range_in_shop_timezone(date)
    orders = rest_get_all_pages("/orders.json",
      status: "any",
      created_at_min: min,
      created_at_max: max,
      fields: "subtotal_price,total_shipping_price_set,total_tax")
    orders.sum do |o|
      o["subtotal_price"].to_d +
        o.dig("total_shipping_price_set", "shop_money", "amount").to_d +
        o["total_tax"].to_d
    end
  end

  # Query all refunded/partially_refunded orders via GraphQL,
  # filter refunds by created_at in shop timezone for the target date.
  # Returns = refund_line_items subtotal - refund_discrepancy adjustments
  def fetch_refunds_total_via_graphql(date)
    min_time = @timezone.parse(date.to_s).beginning_of_day.utc
    max_time = @timezone.parse(date.to_s).end_of_day.utc

    client = build_graphql_client
    cursor = nil
    total_returns = BigDecimal("0")

    loop do
      after_clause = cursor ? ", after: \"#{cursor}\"" : ""
      query = <<~GQL
        {
          orders(first: 50#{after_clause}, query: "financial_status:partially_refunded OR financial_status:refunded") {
            edges {
              cursor
              node {
                refunds(first: 20) {
                  createdAt
                  refundLineItems(first: 50) {
                    edges {
                      node {
                        subtotalSet {
                          shopMoney { amount }
                        }
                      }
                    }
                  }
                  orderAdjustments {
                    kind
                    amountSet {
                      shopMoney { amount }
                    }
                  }
                }
              }
            }
            pageInfo {
              hasNextPage
            }
          }
        }
      GQL

      response = client.query(query: query)
      data = response.body.dig("data", "orders")
      break unless data

      edges = data["edges"] || []
      break if edges.empty?

      edges.each do |edge|
        order = edge["node"]
        (order["refunds"] || []).each do |refund|
          refund_at = Time.parse(refund["createdAt"]).utc rescue nil
          next unless refund_at
          next unless refund_at >= min_time && refund_at <= max_time

          li_total = (refund.dig("refundLineItems", "edges") || []).sum do |e|
            e.dig("node", "subtotalSet", "shopMoney", "amount").to_d
          end
          discrepancy = (refund["orderAdjustments"] || [])
            .select { |a| a["kind"] == "REFUND_DISCREPANCY" }
            .sum { |a| a.dig("amountSet", "shopMoney", "amount").to_d }

          total_returns += li_total - discrepancy
        end
      end

      break unless data.dig("pageInfo", "hasNextPage")
      cursor = edges.last["cursor"]
    end

    total_returns
  end

  def build_graphql_client
    session = ShopifyAPI::Auth::Session.new(
      shop: @shop_domain,
      access_token: @access_token
    )
    ShopifyAPI::Clients::Graphql::Admin.new(session: session)
  end

  def rest_get(path, **params)
    response = HTTParty.get(
      "#{@base_url}#{path}",
      query: params,
      headers: rest_headers
    )
    raise "Shopify API error (#{response.code}): #{response.body}" unless response.success?
    response.parsed_response
  end

  def rest_get_all_pages(path, **params)
    all_records = []
    url = "#{@base_url}#{path}"
    query = params.merge(limit: 250)

    loop do
      response = HTTParty.get(url, query: query, headers: rest_headers)
      raise "Shopify API error (#{response.code}): #{response.body}" unless response.success?

      records = response.parsed_response["orders"] || []
      all_records.concat(records)
      break if records.size < 250

      link = response.headers["link"]
      break unless link&.include?('rel="next"')

      next_url = link.match(/<([^>]+)>;\s*rel="next"/)&.captures&.first
      break unless next_url

      url = next_url
      query = {}
    end

    all_records
  end

  def rest_headers
    {
      "X-Shopify-Access-Token" => @access_token,
      "Content-Type" => "application/json"
    }
  end
end
