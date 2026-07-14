class DashboardMetricsService
  RANGES = {
    "today" => -> { Date.current..Date.current },
    "yesterday" => -> { Date.yesterday..Date.yesterday },
    "past_7_days" => -> { 6.days.ago.to_date..Date.current },
    "this_month" => -> { Date.current.beginning_of_month..Date.current },
    "last_month" => -> { 1.month.ago.beginning_of_month.to_date..1.month.ago.end_of_month.to_date },
    "past_30_days" => -> { 29.days.ago.to_date..Date.current }
  }.freeze

  def initialize(scope, range_key: "past_7_days", start_date: nil, end_date: nil, shopify_store: nil)
    @scope = scope
    @shopify_store = shopify_store
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

    if @shopify_store
      # Narrow within the existing group/company scope — do NOT replace ad_scope
      # with @shopify_store.ad_accounts, which would pull in ad accounts assigned
      # to other groups that happen to be linked to this store.
      store_scope = store_scope.where(id: @shopify_store.id)
      ad_scope    = ad_scope.where(shopify_store_id: @shopify_store.id)
    end

    shopify = shopify.where(shopify_store_id: store_scope.select(:id))
    ad = ad.where(ad_account_id: ad_scope.select(:id))

    sessions = shopify.sum(:sessions)
    orders = shopify.sum(:orders_count)
    new_customer_orders = shopify.sum(:new_customer_orders_count)
    revenue = shopify.sum(:revenue)
    gross_revenue = shopify.sum(:gross_revenue)
    refunds = shopify.sum(:refunds)
    total_tax = shopify.sum(:total_tax)
    transaction_fees = shopify.sum(:transaction_fees)
    net_revenue = gross_revenue - refunds - total_tax - transaction_fees
    ad_spend = ad.sum(:spend)

    cogs, coverage = aggregate_cogs(store_scope, range)
    shipping_total, shipping_breakdown = aggregate_shipping(store_scope, range)
    gross_profit = revenue - cogs
    net_profit = gross_profit - shipping_total - ad_spend

    {
      sessions: sessions,
      orders: orders,
      new_customer_orders: new_customer_orders,
      revenue: revenue,
      gross_revenue: gross_revenue,
      refunds: refunds,
      total_tax: total_tax,
      transaction_fees: transaction_fees,
      net_revenue: net_revenue,
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
      cogs_coverage_pct: coverage,
      shipping_cost: shipping_total,
      shipping_coverage_pct: shipping_breakdown[:coverage],
      shipping_coverage_actual_pct: shipping_breakdown[:actual],
      shipping_coverage_estimated_pct: shipping_breakdown[:estimated_only]
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

  def aggregate_shipping(store_scope, range)
    total = BigDecimal("0")
    count_total = 0
    count_actual = 0
    count_estimated_only = 0

    store_scope.find_each do |store|
      tz = store.active_timezone
      start_utc = tz.local(range.first.year, range.first.month, range.first.day).utc
      end_utc   = tz.local(range.last.year,  range.last.month,  range.last.day).end_of_day.utc

      orders = Order.where(shopify_store_id: store.id, ordered_at: start_utc..end_utc)

      total += orders.sum("COALESCE(actual_shipping_cost, estimated_shipping_cost, 0)")
      count_total          += orders.count
      count_actual         += orders.where.not(actual_shipping_cost: nil).count
      count_estimated_only += orders.where(actual_shipping_cost: nil).where.not(estimated_shipping_cost: nil).count
    end

    pct = ->(n) { count_total > 0 ? (n.to_f / count_total * 100).round(1) : nil }
    [
      total,
      {
        coverage:       pct.call(count_actual + count_estimated_only),
        actual:         pct.call(count_actual),
        estimated_only: pct.call(count_estimated_only)
      }
    ]
  end

  def previous_range
    days = (@date_range.last - @date_range.first).to_i + 1
    prev_end = @date_range.first - 1.day
    prev_start = prev_end - (days - 1).days
    prev_start..prev_end
  end
end
