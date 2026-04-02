class ShopifyAnalyticsService
  def initialize(shop_domain:, access_token:, store_id:, timezone: "UTC")
    @shop_domain = shop_domain
    @access_token = access_token
    @store_id = store_id
    @timezone = ActiveSupport::TimeZone[timezone] || ActiveSupport::TimeZone["UTC"]
  end

  def sync_date(date)
    min_time = @timezone.parse(date.to_s).beginning_of_day.utc
    max_time = @timezone.parse(date.to_s).end_of_day.utc

    client = build_graphql_client
    orders_count, gross_revenue = fetch_orders_via_graphql(client, min_time, max_time)

    refunds_total = fetch_refunds_via_graphql(client, min_time, max_time)

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

  def build_graphql_client
    session = ShopifyAPI::Auth::Session.new(
      shop: @shop_domain,
      access_token: @access_token
    )
    ShopifyAPI::Clients::Graphql::Admin.new(session: session)
  end

  # Fetch orders created on target date via GraphQL with pagination.
  # Returns [orders_count, gross_revenue]
  def fetch_orders_via_graphql(client, min_time, max_time)
    cursor = nil
    total_count = 0
    total_revenue = BigDecimal("0")

    loop do
      after_clause = cursor ? ", after: \"#{cursor}\"" : ""
      query = <<~GQL
        {
          orders(first: 100#{after_clause}, query: "created_at:>='#{min_time.iso8601}' AND created_at:<='#{max_time.iso8601}'") {
            edges {
              cursor
              node {
                subtotalPriceSet { shopMoney { amount } }
                totalShippingPriceSet { shopMoney { amount } }
                totalTaxSet { shopMoney { amount } }
              }
            }
            pageInfo { hasNextPage }
          }
        }
      GQL

      response = client.query(query: query)
      data = response.body.dig("data", "orders")
      break unless data

      edges = data["edges"] || []
      break if edges.empty?

      edges.each do |edge|
        node = edge["node"]
        total_count += 1
        total_revenue += node.dig("subtotalPriceSet", "shopMoney", "amount").to_d +
          node.dig("totalShippingPriceSet", "shopMoney", "amount").to_d +
          node.dig("totalTaxSet", "shopMoney", "amount").to_d
      end

      break unless data.dig("pageInfo", "hasNextPage")
      cursor = edges.last["cursor"]
    end

    [ total_count, total_revenue ]
  end

  # Fetch refunds processed on target date via GraphQL.
  # Queries partially_refunded and refunded orders separately to avoid
  # Shopify query syntax issues with OR + updated_at filters.
  # Returns = refund_line_items subtotal + shipping refunds - all order adjustments
  def fetch_refunds_via_graphql(client, min_time, max_time)
    total_returns = BigDecimal("0")

    %w[partially_refunded refunded].each do |status|
      total_returns += fetch_refunds_for_status(client, min_time, max_time, status)
    end

    total_returns
  end

  def fetch_refunds_for_status(client, min_time, max_time, status)
    cursor = nil
    total = BigDecimal("0")
    # Use date-only format; Shopify's query parser can't handle ISO8601 timestamps
    updated_since = min_time.in_time_zone(@timezone).to_date.iso8601

    loop do
      after_clause = cursor ? ", after: \"#{cursor}\"" : ""
      query = <<~GQL
        {
          orders(first: 50#{after_clause}, sortKey: UPDATED_AT, reverse: true, query: "financial_status:#{status} updated_at:>=#{updated_since}") {
            edges {
              cursor
              node {
                refunds(first: 20) {
                  createdAt
                  refundLineItems(first: 50) {
                    edges {
                      node {
                        subtotalSet { shopMoney { amount } }
                        totalTaxSet { shopMoney { amount } }
                      }
                    }
                  }
                  refundShippingLines(first: 10) {
                    edges {
                      node {
                        subtotalAmountSet { shopMoney { amount } }
                        taxAmountSet { shopMoney { amount } }
                      }
                    }
                  }
                  orderAdjustments(first: 10) {
                    edges {
                      node {
                        reason
                        amountSet { shopMoney { amount } }
                      }
                    }
                  }
                }
              }
            }
            pageInfo { hasNextPage }
          }
        }
      GQL

      response = client.query(query: query)
      data = response.body.dig("data", "orders")
      break unless data

      edges = data["edges"] || []
      break if edges.empty?

      edges.each do |edge|
        (edge.dig("node", "refunds") || []).each do |refund|
          refund_at = Time.parse(refund["createdAt"]).utc rescue nil
          next unless refund_at
          next unless refund_at >= min_time && refund_at <= max_time

          li_total = (refund.dig("refundLineItems", "edges") || []).sum do |e|
            e.dig("node", "subtotalSet", "shopMoney", "amount").to_s.to_d +
              e.dig("node", "totalTaxSet", "shopMoney", "amount").to_s.to_d
          end
          shipping_total = (refund.dig("refundShippingLines", "edges") || []).sum do |e|
            e.dig("node", "subtotalAmountSet", "shopMoney", "amount").to_s.to_d +
              e.dig("node", "taxAmountSet", "shopMoney", "amount").to_s.to_d
          end

          # Sum ALL adjustment types (includes settled pending refunds)
          adjustments = (refund.dig("orderAdjustments", "edges") || []).map { |e| e["node"] }
          discrepancy = adjustments.sum { |a| a.dig("amountSet", "shopMoney", "amount").to_d }

          net = li_total + shipping_total - discrepancy
          total += net unless net.zero?
        end
      end

      break unless data.dig("pageInfo", "hasNextPage")
      cursor = edges.last["cursor"]
    end

    total
  end
end
