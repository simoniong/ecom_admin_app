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

    it "returns date range metadata" do
      result = described_class.new(user, range_key: "yesterday").call
      expect(result[:date_range]).to eq(Date.yesterday..Date.yesterday)
      expect(result[:range_key]).to eq("yesterday")
    end
  end

  describe "all range keys" do
    %w[today yesterday past_7_days this_month last_month past_30_days].each do |key|
      it "handles #{key} range" do
        result = described_class.new(user, range_key: key).call
        expect(result[:current]).to include(:sessions, :orders, :revenue, :conversion_rate, :ad_spend, :roas)
        expect(result[:previous]).to include(:sessions, :orders, :revenue, :conversion_rate, :ad_spend, :roas)
      end
    end
  end
end
