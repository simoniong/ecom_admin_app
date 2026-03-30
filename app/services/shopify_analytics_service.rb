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
    refunds_total = fetch_refunds_total(date)

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
    response = get("/orders/count.json",
      status: "any",
      created_at_min: min,
      created_at_max: max)
    response["count"] || 0
  end

  # Gross revenue from orders created on this date (original amounts, before refunds)
  def fetch_gross_revenue(date)
    min, max = date_range_in_shop_timezone(date)
    orders = get("/orders.json",
      status: "any",
      created_at_min: min,
      created_at_max: max,
      fields: "subtotal_price,total_shipping_price_set,total_tax",
      limit: 250)
    (orders["orders"] || []).sum do |o|
      subtotal = o["subtotal_price"].to_d
      shipping = o.dig("total_shipping_price_set", "shop_money", "amount").to_d
      tax = o["total_tax"].to_d
      subtotal + shipping + tax
    end
  end

  # Sum of refunds processed on this date (across all orders, not just today's)
  def fetch_refunds_total(date)
    min, max = date_range_in_shop_timezone(date)
    # Fetch orders that have refunds — we need to check all orders, not just today's
    # Use a wider window and filter refunds by date
    orders = get("/orders.json",
      status: "any",
      updated_at_min: min,
      updated_at_max: max,
      fields: "refunds",
      limit: 250)
    (orders["orders"] || []).sum do |order|
      (order["refunds"] || []).sum do |refund|
        refund_time = Time.zone.parse(refund["created_at"]) rescue nil
        next 0 unless refund_time
        refund_date = refund_time.in_time_zone(@timezone).to_date
        next 0 unless refund_date == date

        # Sum refund line item amounts + shipping refund
        line_items_total = (refund["refund_line_items"] || []).sum { |li| li["subtotal"].to_d }
        shipping_total = (refund.dig("order_adjustments") || [])
          .select { |a| a["kind"] == "shipping_refund" }
          .sum { |a| a["amount"].to_d.abs }
        line_items_total + shipping_total
      end
    end
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
