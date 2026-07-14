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
      # No daily metrics → revenue/cogs/ad_spend are 0, so net_profit = -shipping.
      expect(metrics[:net_profit]).to eq(metrics[:gross_profit] - metrics[:shipping_cost] - metrics[:ad_spend])
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
                                    revenue: 100, orders_count: 1)
      result = described_class.new(company, range_key: "today").call
      expect(result[:current][:gross_profit]).to eq(75)   # 100 - 25
      expect(result[:current][:net_profit]).to eq(75)     # no ad spend
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
      metric(gross_revenue: 1000, refunds: 100, total_tax: 60, transaction_fees: 40, revenue: 900)

      result = described_class.new(company, range_key: "today").call[:current]

      # revenue keeps its existing definition; net_revenue is strictly separate
      expect(result[:revenue]).to eq(900)
      expect(result[:net_revenue]).not_to eq(result[:revenue])
    end
  end
end
