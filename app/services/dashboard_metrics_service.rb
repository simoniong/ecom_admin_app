class DashboardMetricsService
  RANGES = {
    "today" => -> { Date.current..Date.current },
    "yesterday" => -> { Date.yesterday..Date.yesterday },
    "past_7_days" => -> { 6.days.ago.to_date..Date.current },
    "this_month" => -> { Date.current.beginning_of_month..Date.current },
    "last_month" => -> { 1.month.ago.beginning_of_month.to_date..1.month.ago.end_of_month.to_date },
    "past_30_days" => -> { 29.days.ago.to_date..Date.current }
  }.freeze

  def initialize(user, range_key: "past_7_days", start_date: nil, end_date: nil)
    @user = user
    if start_date.present? && end_date.present?
      @range_key = "custom"
      @date_range = begin
        parsed_start = Date.parse(start_date.to_s)
        parsed_end = Date.parse(end_date.to_s)
        parsed_start = [ parsed_start, parsed_end ].min
        parsed_start..parsed_end
      rescue ArgumentError
        RANGES["past_7_days"].call
      end
    else
      @range_key = range_key
      @date_range = RANGES.fetch(range_key, RANGES["past_7_days"]).call
    end
  end

  def call
    current = aggregate_metrics(@date_range)
    previous = aggregate_metrics(previous_range)
    {
      current: current,
      previous: previous,
      date_range: @date_range,
      range_key: @range_key
    }
  end

  private

  def aggregate_metrics(range)
    shopify = ShopifyDailyMetric.for_date_range(range)
    ad = AdDailyMetric.for_date_range(range)

    # Scope to user's stores if association exists
    if @user.respond_to?(:shopify_stores)
      shopify = shopify.where(shopify_store_id: @user.shopify_stores.select(:id))
    end
    if @user.respond_to?(:ad_accounts)
      ad = ad.where(ad_account_id: @user.ad_accounts.select(:id))
    end

    sessions = shopify.sum(:sessions)
    orders = shopify.sum(:orders_count)
    revenue = shopify.sum(:revenue)
    ad_spend = ad.sum(:spend)

    {
      sessions: sessions,
      orders: orders,
      revenue: revenue,
      conversion_rate: sessions > 0 ? (orders.to_f / sessions * 100).round(2) : 0,
      ad_spend: ad_spend,
      roas: ad_spend > 0 ? (revenue / ad_spend).round(2) : 0
    }
  end

  def previous_range
    days = (@date_range.last - @date_range.first).to_i + 1
    prev_end = @date_range.first - 1.day
    prev_start = prev_end - (days - 1).days
    prev_start..prev_end
  end
end
