require "rails_helper"

RSpec.describe DashboardMetricsService do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user) }
  let(:ad_account) { create(:ad_account, user: user) }

  describe "#call" do
    it "returns aggregated metrics for the date range" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 100, orders_count: 5, revenue: 500)
      create(:shopify_daily_metric, shopify_store: store, date: 1.day.ago, sessions: 200, orders_count: 10, revenue: 1000)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 50)
      create(:ad_daily_metric, ad_account: ad_account, date: 1.day.ago, spend: 75)

      result = described_class.new(user, range_key: "past_7_days").call

      expect(result[:current][:sessions]).to eq(300)
      expect(result[:current][:orders]).to eq(15)
      expect(result[:current][:revenue]).to eq(1500)
      expect(result[:current][:ad_spend]).to eq(125)
    end

    it "calculates conversion rate" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 200, orders_count: 10, revenue: 500)

      result = described_class.new(user, range_key: "today").call

      expect(result[:current][:conversion_rate]).to eq(5.0)
    end

    it "returns zero conversion rate when no sessions" do
      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:conversion_rate]).to eq(0)
    end

    it "calculates ROAS" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 100, orders_count: 5, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 100)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:roas]).to eq(5.0)
    end

    it "returns zero ROAS when no ad spend" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 100, orders_count: 5, revenue: 500)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:roas]).to eq(0)
    end

    it "calculates average order value" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 100, orders_count: 5, revenue: 500)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:avg_order_value]).to eq(100.0)
    end

    it "returns zero avg order value when no orders" do
      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:avg_order_value]).to eq(0)
    end

    it "includes previous period metrics" do
      # Current period: today
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 100, orders_count: 5, revenue: 500)
      # Previous period: yesterday
      create(:shopify_daily_metric, shopify_store: store, date: 1.day.ago, sessions: 80, orders_count: 3, revenue: 300)

      result = described_class.new(user, range_key: "today").call

      expect(result[:previous][:sessions]).to eq(80)
      expect(result[:previous][:orders]).to eq(3)
    end

    it "scopes metrics to current user" do
      other_user = create(:user)
      other_store = create(:shopify_store, user: other_user)
      create(:shopify_daily_metric, shopify_store: other_store, date: Date.current, sessions: 999)
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 100)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:sessions]).to eq(100)
    end

    it "defaults to past_7_days for invalid range key" do
      result = described_class.new(user, range_key: "invalid").call
      expect(result[:range_key]).to eq("invalid")
      expect(result[:date_range]).to eq(6.days.ago.to_date..Date.current)
    end

    it "supports custom date range" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.new(2026, 3, 15), sessions: 50, orders_count: 3, revenue: 300)

      result = described_class.new(user, start_date: "2026-03-15", end_date: "2026-03-15").call
      expect(result[:range_key]).to eq("custom")
      expect(result[:current][:orders]).to eq(3)
      expect(result[:current][:revenue]).to eq(300)
    end

    it "returns date range metadata" do
      result = described_class.new(user, range_key: "yesterday").call
      expect(result[:date_range]).to eq(Date.yesterday..Date.yesterday)
      expect(result[:range_key]).to eq("yesterday")
    end

    it "calculates CPA as ad_spend divided by orders" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 100, orders_count: 10, new_customer_orders_count: 4, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 50)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:cpa]).to eq(5.0)
    end

    it "returns nil CPA when there are no orders" do
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 50)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:cpa]).to be_nil
    end

    it "returns nil CPA when there is no ad spend" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 4, revenue: 500)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:cpa]).to be_nil
    end

    it "calculates new_customer_cpa as ad_spend divided by new_customer_orders_count" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 4, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 80)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:new_customer_cpa]).to eq(20.0)
    end

    it "returns nil new_customer_cpa when new_customer_orders_count is zero" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 0, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 80)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:new_customer_cpa]).to be_nil
    end

    it "exposes new_customer_orders so the view can render context" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 4, revenue: 500)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:new_customer_orders]).to eq(4)
    end

    it "computes previous-period CPA against the previous range" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 4, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 50)
      create(:shopify_daily_metric, shopify_store: store, date: Date.yesterday, orders_count: 5, new_customer_orders_count: 2, revenue: 250)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.yesterday, spend: 100)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:cpa]).to eq(5.0)
      expect(result[:previous][:cpa]).to eq(20.0)
    end

    context "when scoped to a single store" do
      let(:store_other) { create(:shopify_store, user: user) }

      it "aggregates only the selected store's shopify metrics" do
        create(:shopify_daily_metric, shopify_store: store, date: Date.current, revenue: 500, orders_count: 5, sessions: 100)
        create(:shopify_daily_metric, shopify_store: store_other, date: Date.current, revenue: 999, orders_count: 9, sessions: 200)

        result = described_class.new(user, range_key: "today", shopify_store: store).call

        expect(result[:current][:revenue]).to eq(500)
        expect(result[:current][:orders]).to eq(5)
      end

      it "restricts ad spend to the selected store's ad accounts" do
        store_ad = create(:ad_account, user: user, shopify_store: store)
        other_ad = create(:ad_account, user: user, shopify_store: store_other)
        create(:ad_daily_metric, ad_account: store_ad, date: Date.current, spend: 30)
        create(:ad_daily_metric, ad_account: other_ad, date: Date.current, spend: 70)

        result = described_class.new(user, range_key: "today", shopify_store: store).call

        expect(result[:current][:ad_spend]).to eq(30)
      end

      it "does not count ad accounts outside the scope even if linked to the store" do
        company = user.companies.first
        group_a = create(:group, company: company)
        group_b = create(:group, company: company)
        scoped_store = create(:shopify_store, company: company, user: user, group: group_a)
        in_group_ad  = create(:ad_account, company: company, user: user, group: group_a, shopify_store: scoped_store)
        other_group_ad = create(:ad_account, company: company, user: user, group: group_b, shopify_store: scoped_store)
        create(:ad_daily_metric, ad_account: in_group_ad, date: Date.current, spend: 40)
        create(:ad_daily_metric, ad_account: other_group_ad, date: Date.current, spend: 60)

        result = described_class.new(group_a, range_key: "today", shopify_store: scoped_store).call

        expect(result[:current][:ad_spend]).to eq(40)
      end
    end
  end

  describe "shipping cost aggregation" do
    let(:user) { create(:user) }
    let(:company) { user.companies.first }
    let(:store) { create(:shopify_store, user: user, company: company, timezone: "UTC") }
    let(:customer) { create(:customer, shopify_store: store) }

    def order_on(day, estimated: nil, actual: nil)
      create(:order, customer: customer, shopify_store: store,
             ordered_at: store.active_timezone.local(2026, 4, day, 12),
             estimated_shipping_cost: estimated, actual_shipping_cost: actual, total_price: 100)
    end

    # Public interface: returns the {current:, previous:} hash; read :current.
    subject(:metrics) do
      described_class.new(company, start_date: "2026-04-01", end_date: "2026-04-30").call.fetch(:current)
    end

    it "sums COALESCE(actual, estimated, 0) into :shipping_cost" do
      order_on(5, estimated: 10, actual: nil)
      order_on(6, estimated: 10, actual: 7)   # actual wins → 7
      order_on(7, estimated: nil, actual: nil) # 0
      expect(metrics[:shipping_cost]).to eq(17)
    end

    it "reports coverage breakdown" do
      order_on(5, estimated: 10, actual: nil)  # estimated-only
      order_on(6, estimated: 10, actual: 7)    # actual
      order_on(7, estimated: nil, actual: nil) # missing
      expect(metrics[:shipping_coverage_actual_pct]).to eq(33.3)
      expect(metrics[:shipping_coverage_estimated_pct]).to eq(33.3)
      expect(metrics[:shipping_coverage_pct]).to eq(66.7)
    end

    it "subtracts shipping from net_profit" do
      order_on(5, estimated: 10, actual: nil)
      # No daily metrics → net_revenue/cogs/ad_spend are 0, so net_profit = -shipping.
      # Assert the current (net_revenue-based) identity, not the old revenue-based one.
      expect(metrics[:net_profit]).to eq(metrics[:net_revenue] - metrics[:cogs] - metrics[:shipping_cost] - metrics[:ad_spend])
    end
  end

  describe "all range keys" do
    %w[today yesterday past_7_days this_month last_month past_30_days].each do |key|
      it "handles #{key} range" do
        result = described_class.new(user, range_key: key).call
        expect(result[:current]).to include(:sessions, :orders, :revenue, :avg_order_value, :conversion_rate, :ad_spend, :roas)
        expect(result[:previous]).to include(:sessions, :orders, :revenue, :avg_order_value, :conversion_rate, :ad_spend, :roas)
      end
    end
  end

  describe "COGS / gross / net profit" do
    let(:cogs_user) { create(:user) }
    let(:company) { cogs_user.companies.first }
    let!(:store) { create(:shopify_store, user: cogs_user, company: company, timezone: "UTC") }
    let!(:customer) { create(:customer, shopify_store: store) }
    let!(:order) do
      create(:order, customer: customer, shopify_store: store,
                     total_price: 100, ordered_at: Date.current.beginning_of_day)
    end

    before do
      create(:order_line_item, order: order, quantity: 2, unit_cost_snapshot: 10) # 20
      create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: 5)  # 5
    end

    it "computes cogs over the date range" do
      result = described_class.new(company, range_key: "today").call
      expect(result[:current][:cogs]).to eq(25)
    end

    it "computes gross_profit and net_profit" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current,
                                    gross_revenue: 100, revenue: 100, orders_count: 1)
      result = described_class.new(company, range_key: "today").call
      expect(result[:current][:gross_profit]).to eq(75)   # revenue 100 - cogs 25
      expect(result[:current][:net_profit]).to eq(75)     # net_revenue 100 - cogs 25 (no tax/fees/ad)
    end

    it "reports cogs_coverage_pct" do
      create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: nil)
      result = described_class.new(company, range_key: "today").call
      expect(result[:current][:cogs_coverage_pct]).to eq(66.7)
    end
  end

  describe "net revenue breakdown" do
    let(:company) { create(:company) }
    let(:store) { create(:shopify_store, company: company) }

    def metric(attrs)
      create(:shopify_daily_metric, { shopify_store: store, date: Date.current }.merge(attrs))
    end

    it "aggregates the breakdown columns and derives net_revenue" do
      metric(
        gross_revenue: 1000, refunds: 100, total_tax: 60, transaction_fees: 40,
        revenue: 900
      )

      result = described_class.new(company, range_key: "today").call[:current]

      expect(result[:gross_revenue]).to eq(1000)
      expect(result[:refunds]).to eq(100)
      expect(result[:total_tax]).to eq(60)
      expect(result[:transaction_fees]).to eq(40)
      expect(result[:net_revenue]).to eq(800) # 1000 - 100 - 60 - 40
    end

    it "leaves the legacy revenue-derived metrics unchanged" do
      # orders_count comes from the factory default (20); no line items / orders /
      # ad accounts exist, so cogs, shipping, and ad_spend are all 0.
      metric(gross_revenue: 1000, refunds: 100, total_tax: 60, transaction_fees: 40, revenue: 900)

      result = described_class.new(company, range_key: "today").call[:current]

      # revenue keeps its existing definition; net_revenue (800) is strictly separate.
      expect(result[:revenue]).to eq(900)
      expect(result[:net_revenue]).to eq(800)
      expect(result[:net_revenue]).not_to eq(result[:revenue])

      # Every legacy revenue-derived metric must still key off revenue (900),
      # not net_revenue (800). These values would all differ if net_revenue leaked in.
      expect(result[:avg_order_value]).to eq(45.0)     # 900 / 20 orders (net would give 40.0)
      expect(result[:gross_profit]).to eq(900)         # revenue - cogs(0), stays revenue-based
      expect(result[:gross_margin_pct]).to eq(100.0)   # gross_profit / revenue * 100

      # net_profit / net_margin now key off net_revenue (800), not revenue (900).
      expect(result[:net_profit]).to eq(800)           # net_revenue 800 - cogs 0 - shipping 0 - ad 0
      expect(result[:net_margin_pct]).to eq(100.0)     # net_profit 800 / net_revenue 800
    end
  end

  describe "net profit basis (option B: net_revenue)" do
    let(:profit_user) { create(:user) }
    let(:company) { profit_user.companies.first }
    let!(:store) { create(:shopify_store, user: profit_user, company: company, timezone: "UTC") }
    let!(:customer) { create(:customer, shopify_store: store) }
    let!(:order) do
      create(:order, customer: customer, shopify_store: store,
                     total_price: 1000, ordered_at: Date.current.beginning_of_day)
    end

    before do
      create(:order_line_item, order: order, quantity: 2, unit_cost_snapshot: 100) # cogs 200
    end

    it "bases net_profit on net_revenue, deducting tax and fees" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current,
             gross_revenue: 1000, refunds: 0, total_tax: 60, transaction_fees: 40,
             revenue: 1000, orders_count: 1)

      m = described_class.new(company, range_key: "today").call[:current]

      expect(m[:revenue]).to eq(1000)
      expect(m[:net_revenue]).to eq(900)      # 1000 - 60 - 40
      expect(m[:cogs]).to eq(200)
      expect(m[:gross_profit]).to eq(800)     # unchanged: revenue 1000 - cogs 200

      # Net Profit is net_revenue-based: 900 - 200 - shipping(0) - ad(0) = 700.
      # Old revenue-based formula would give 800; omitting tax/fees would too.
      expect(m[:net_profit]).to eq(700)

      # Net Margin denominator is net_revenue (900), not revenue (1000):
      # 700 / 900 = 77.78%. Against revenue it would be 70.0%.
      expect(m[:net_margin_pct]).to eq(77.78)
    end

    it "returns nil net_margin_pct when net_revenue is not positive (negative)" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current,
             gross_revenue: 1000, refunds: 1200, total_tax: 0, transaction_fees: 0,
             revenue: 0, orders_count: 1)

      m = described_class.new(company, range_key: "today").call[:current]

      expect(m[:net_revenue]).to eq(-200)     # 1000 - 1200 → negative, exercises the guard's negative branch
      expect(m[:net_margin_pct]).to be_nil
    end
  end

  describe "shipping variance metrics" do
    let(:user)  { create(:user) }
    let(:company) { user.companies.first }
    let(:store) { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2, timezone: "UTC") }
    let(:customer) { create(:customer, shopify_store: store) }

    def order_with(estimated:, parcel_costs:, name:)
      o = create(:order, customer: customer, shopify_store: store, name: name,
                         estimated_shipping_cost: estimated, ordered_at: 1.day.ago)
      parcel_costs.each_with_index do |c, i|
        create(:parcel, shopify_store: store, order: o, identifier: "#{name}-#{i}", cost_amount: c)
      end
      o
    end

    it "compares actual against estimated only on orders that have BOTH" do
      order_with(estimated: 10, parcel_costs: [ 15 ], name: "PKS#1")          # comparable: +5
      order_with(estimated: 20, parcel_costs: [ 18 ], name: "PKS#2")          # comparable: -2
      order_with(estimated: nil, parcel_costs: [ 99 ], name: "PKS#3")         # actual only — excluded from variance
      create(:order, customer: customer, shopify_store: store, name: "PKS#4",
                     estimated_shipping_cost: 30, ordered_at: 1.day.ago)      # estimate only — excluded

      metrics = described_class.new(company, range_key: "past_7_days").call[:current]

      expect(metrics[:shipping_estimated_total]).to eq(30)   # 10 + 20
      expect(metrics[:shipping_actual_total]).to eq(33)      # 15 + 18
      expect(metrics[:shipping_variance]).to eq(3)
      expect(metrics[:shipping_variance_pct]).to eq(10.0)
    end

    it "counts multi-parcel orders" do
      order_with(estimated: 10, parcel_costs: [ 5, 5, 5 ], name: "PKS#5")
      order_with(estimated: 10, parcel_costs: [ 9 ], name: "PKS#6")

      metrics = described_class.new(company, range_key: "past_7_days").call[:current]

      expect(metrics[:multi_parcel_orders_count]).to eq(1)
    end

    it "returns nil variance_pct when there is nothing comparable" do
      metrics = described_class.new(company, range_key: "past_7_days").call[:current]

      expect(metrics[:shipping_variance_pct]).to be_nil
      expect(metrics[:multi_parcel_orders_count]).to eq(0)
    end

    it "computes shipping_comparable_pct against the comparable set, distinct from shipping_coverage_actual_pct" do
      order_with(estimated: 10, parcel_costs: [ 15 ], name: "PKS#1")  # comparable
      order_with(estimated: 20, parcel_costs: [ 18 ], name: "PKS#2")  # comparable
      order_with(estimated: nil, parcel_costs: [ 99 ], name: "PKS#3") # actual-only: counts toward
      #                                                                 shipping_coverage_actual_pct
      #                                                                 but is NOT comparable (no estimate)
      create(:order, customer: customer, shopify_store: store, name: "PKS#4",
                     estimated_shipping_cost: 30, ordered_at: 1.day.ago) # estimated-only

      metrics = described_class.new(company, range_key: "past_7_days").call[:current]

      # 4 orders total. Comparable (has BOTH figures): PKS#1, PKS#2 → 2/4 = 50%.
      # Has an actual figure at all: PKS#1, PKS#2, PKS#3 → 3/4 = 75%.
      # These must differ — that's the whole point of exposing a distinct key.
      expect(metrics[:shipping_comparable_pct]).to eq(50.0)
      expect(metrics[:shipping_coverage_actual_pct]).to eq(75.0)
      expect(metrics[:shipping_comparable_pct]).not_to eq(metrics[:shipping_coverage_actual_pct])
    end
  end

  describe "shipping variance across multiple stores" do
    let(:user)    { create(:user) }
    let(:company) { user.companies.first }
    let(:store_a) { create(:shopify_store, user: user, company: company, timezone: "UTC") }
    let(:store_b) { create(:shopify_store, user: user, company: company, timezone: "Asia/Shanghai") }
    let(:customer_a) { create(:customer, shopify_store: store_a) }
    let(:customer_b) { create(:customer, shopify_store: store_b) }

    def order_for(store, customer, estimated:, parcel_costs:, name:)
      o = create(:order, customer: customer, shopify_store: store, name: name,
                         estimated_shipping_cost: estimated, ordered_at: 1.day.ago)
      parcel_costs.each_with_index do |c, i|
        create(:parcel, shopify_store: store, order: o, identifier: "#{name}-#{i}", cost_amount: c)
      end
      o
    end

    it "sums comparable totals and multi-parcel counts across stores instead of overwriting" do
      # Store A (UTC): one comparable, multi-parcel order.
      order_for(store_a, customer_a, estimated: 10, parcel_costs: [ 6, 6 ], name: "PKS#A1") # actual 12

      # Store B (Asia/Shanghai): one comparable, multi-parcel order, plus one
      # estimate-only order that must NOT count toward "comparable".
      order_for(store_b, customer_b, estimated: 20, parcel_costs: [ 9, 9 ], name: "PKS#B1") # actual 18
      order_for(store_b, customer_b, estimated: 25, parcel_costs: [], name: "PKS#B2")       # estimate-only

      metrics = described_class.new(company, range_key: "past_7_days").call[:current]

      # If the accumulators were `=` instead of `+=`, whichever store is processed
      # last would clobber the other's contribution. Neither store's numbers alone
      # (10/12/1 or 20/18/1) match the true sum below, so this fails under that bug.
      expect(metrics[:shipping_estimated_total]).to eq(30)   # 10 + 20
      expect(metrics[:shipping_actual_total]).to eq(30)      # 12 + 18
      expect(metrics[:multi_parcel_orders_count]).to eq(2)   # 1 + 1

      # 3 orders total (2 comparable + 1 estimate-only). shipping_comparable_pct
      # must sum count_comparable across BOTH stores (2/3 = 66.7%). Because
      # `comparable` is scoped per-store inside the loop, a clobbering `=` bug
      # would leave count_comparable at 1 (a single store's own comparable
      # count) no matter which store's find_each iteration runs last — giving
      # 1/3 = 33.3% instead. That distinguishes this from the vacuous case
      # where clobbering would coincidentally still land on the right answer.
      expect(metrics[:shipping_comparable_pct]).to eq(66.7)
    end
  end

  describe "per-store timezone boundary handling in shipping aggregation" do
    let(:user) { create(:user) }
    let(:company) { user.companies.first }
    let(:store) { create(:shopify_store, user: user, company: company, timezone: "Asia/Shanghai") }
    let(:customer) { create(:customer, shopify_store: store) }

    it "counts an order using the store's own timezone, not UTC, at a day boundary" do
      shanghai = ActiveSupport::TimeZone["Asia/Shanghai"]

      # 2026-04-01 02:00 Shanghai local == 2026-03-31 18:00 UTC.
      # That instant is INSIDE the Shanghai-local range for "2026-04-01".."2026-04-30"
      # (which starts at 2026-03-31T16:00:00Z), but OUTSIDE a UTC-computed version of
      # that same range (which would start at 2026-04-01T00:00:00Z). Absolute, fixed
      # dates — no Date.current / freeze_time needed for determinism.
      create(:order, customer: customer, shopify_store: store,
                     ordered_at: shanghai.local(2026, 4, 1, 2, 0, 0),
                     estimated_shipping_cost: 42, actual_shipping_cost: nil, total_price: 100)

      metrics = described_class.new(company, start_date: "2026-04-01", end_date: "2026-04-30").call[:current]

      # Under a UTC-hardcoded aggregate_shipping, this order falls just before the
      # (wrongly computed) range start and is dropped entirely: shipping_cost would
      # be 0 and shipping_coverage_estimated_pct would be nil (no orders at all).
      expect(metrics[:shipping_cost]).to eq(42)
      expect(metrics[:shipping_coverage_estimated_pct]).to eq(100.0)
    end
  end
end
