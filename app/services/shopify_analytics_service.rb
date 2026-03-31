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

  def fetch_gross_revenue(date)
    min, max = date_range_in_shop_timezone(date)
    orders = get_all_pages("/orders.json",
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

  # Refunds processed on this date (across all orders).
  # Queries orders updated on the target date with pagination,
  # then filters refunds by created_at in shop timezone.
  def fetch_refunds_total(date)
    min, max = date_range_in_shop_timezone(date)
    orders = get_all_pages("/orders.json",
      status: "any",
      updated_at_min: min,
      updated_at_max: max,
      fields: "refunds")

    orders.sum do |order|
      (order["refunds"] || []).sum do |refund|
        refund_time = Time.zone.parse(refund["created_at"]) rescue nil
        next 0 unless refund_time
        next 0 unless refund_time.in_time_zone(@timezone).to_date == date

        line_items_total = (refund["refund_line_items"] || []).sum { |li| li["subtotal"].to_d }
        discrepancy = (refund["order_adjustments"] || [])
          .select { |a| a["kind"] == "refund_discrepancy" }
          .sum { |a| a["amount"].to_d }
        line_items_total - discrepancy
      end
    end
  end

  def get(path, **params)
    response = HTTParty.get(
      "#{@base_url}#{path}",
      query: params,
      headers: api_headers
    )
    raise "Shopify API error (#{response.code}): #{response.body}" unless response.success?
    response.parsed_response
  end

  # Paginate through all orders using link header
  def get_all_pages(path, **params)
    all_records = []
    url = "#{@base_url}#{path}"
    query = params.merge(limit: 250)

    loop do
      response = HTTParty.get(url, query: query, headers: api_headers)
      raise "Shopify API error (#{response.code}): #{response.body}" unless response.success?

      records = response.parsed_response["orders"] || []
      all_records.concat(records)
      break if records.size < 250

      # Follow next page via Link header
      link = response.headers["link"]
      break unless link&.include?('rel="next"')

      next_url = link.match(/<([^>]+)>;\s*rel="next"/)&.captures&.first
      break unless next_url

      url = next_url
      query = {} # params are in the URL now
    end

    all_records
  end

  def api_headers
    {
      "X-Shopify-Access-Token" => @access_token,
      "Content-Type" => "application/json"
    }
  end
end
