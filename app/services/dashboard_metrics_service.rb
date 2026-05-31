class DashboardMetricsService
  RANGES = {
    "today" => -> { Date.current..Date.current },
    "yesterday" => -> { Date.yesterday..Date.yesterday },
    "past_7_days" => -> { 6.days.ago.to_date..Date.current },
    "this_month" => -> { Date.current.beginning_of_month..Date.current },
    "last_month" => -> { 1.month.ago.beginning_of_month.to_date..1.month.ago.end_of_month.to_date },
    "past_30_days" => -> { 29.days.ago.to_date..Date.current }
  }.freeze

  def initialize(scope, range_key: "past_7_days", start_date: nil, end_date: nil)
    @scope = scope
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

    store_scope = @scope.respond_to?(:shopify_stores) ? @scope.shopify_stores : ShopifyStore.none
    ad_scope    = @scope.respond_to?(:ad_accounts)    ? @scope.ad_accounts    : AdAccount.none

    shopify = shopify.where(shopify_store_id: store_scope.select(:id))
    ad = ad.where(ad_account_id: ad_scope.select(:id))

    sessions = shopify.sum(:sessions)
    orders = shopify.sum(:orders_count)
    new_customer_orders = shopify.sum(:new_customer_orders_count)
    revenue = shopify.sum(:revenue)
    ad_spend = ad.sum(:spend)

    cogs, coverage = aggregate_cogs(store_scope, range)
    gross_profit = revenue - cogs
    net_profit = gross_profit - ad_spend

    {
      sessions: sessions,
      orders: orders,
      new_customer_orders: new_customer_orders,
      revenue: revenue,
      avg_order_value: orders > 0 ? (revenue / orders).round(2) : 0,
      conversion_rate: sessions > 0 ? (orders.to_f / sessions * 100).round(2) : 0,
      ad_spend: ad_spend,
      roas: ad_spend > 0 ? (revenue / ad_spend).round(2) : 0,
      cpa: (orders > 0 && ad_spend > 0) ? (ad_spend / orders).round(2) : nil,
      new_customer_cpa: (new_customer_orders > 0 && ad_spend > 0) ? (ad_spend / new_customer_orders).round(2) : nil,
      cogs: cogs,
      gross_profit: gross_profit,
      gross_margin_pct: revenue > 0 ? (gross_profit / revenue * 100).round(2) : nil,
      net_profit: net_profit,
      net_margin_pct: revenue > 0 ? (net_profit / revenue * 100).round(2) : nil,
      cogs_coverage_pct: coverage
    }
  end

  def aggregate_cogs(store_scope, range)
    total_cogs = BigDecimal("0")
    total_lines = 0
    covered_lines = 0

    store_scope.find_each do |store|
      tz = store.active_timezone
      start_utc = tz.local(range.first.year, range.first.month, range.first.day).utc
      end_utc   = tz.local(range.last.year,  range.last.month,  range.last.day).end_of_day.utc

      line_items = OrderLineItem.joins(:order)
                                .where(orders: { shopify_store_id: store.id,
                                                 ordered_at: start_utc..end_utc })

      total_cogs    += line_items.sum("quantity * COALESCE(unit_cost_snapshot, 0)")
      total_lines   += line_items.count
      covered_lines += line_items.where.not(unit_cost_snapshot: nil).count
    end

    coverage = total_lines > 0 ? (covered_lines.to_f / total_lines * 100).round(1) : nil
    [ total_cogs, coverage ]
  end

  def previous_range
    days = (@date_range.last - @date_range.first).to_i + 1
    prev_end = @date_range.first - 1.day
    prev_start = prev_end - (days - 1).days
    prev_start..prev_end
  end
end
