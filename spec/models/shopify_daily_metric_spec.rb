require "rails_helper"

RSpec.describe ShopifyDailyMetric, type: :model do
  let(:store) { create(:shopify_store) }
  let(:metric) { create(:shopify_daily_metric, shopify_store: store) }

  it "is valid with valid attributes" do
    expect(metric).to be_valid
  end

  it "requires date" do
    metric.date = nil
    expect(metric).not_to be_valid
  end

  it "validates sessions is non-negative" do
    metric.sessions = -1
    expect(metric).not_to be_valid
  end

  it "validates orders_count is non-negative" do
    metric.orders_count = -1
    expect(metric).not_to be_valid
  end

  it "validates new_customer_orders_count is non-negative" do
    metric.new_customer_orders_count = -1
    expect(metric).not_to be_valid
  end

  it "defaults new_customer_orders_count to 0" do
    fresh = described_class.new(shopify_store: store, date: Date.current)
    expect(fresh.new_customer_orders_count).to eq(0)
  end

  it "allows negative revenue (days with more refunds than sales)" do
    metric.revenue = -50
    expect(metric).to be_valid
  end

  describe ".for_date_range" do
    it "returns metrics within the range" do
      create(:shopify_daily_metric, shopify_store: store, date: 2.days.ago)
      create(:shopify_daily_metric, shopify_store: create(:shopify_store), date: 30.days.ago)

      results = described_class.for_date_range(3.days.ago.to_date..Date.current)
      expect(results.count).to eq(1)
    end
  end
end
