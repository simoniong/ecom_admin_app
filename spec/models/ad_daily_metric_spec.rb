require "rails_helper"

RSpec.describe AdDailyMetric, type: :model do
  let(:ad_account) { create(:ad_account) }
  let(:metric) { create(:ad_daily_metric, ad_account: ad_account) }

  it "is valid with valid attributes" do
    expect(metric).to be_valid
  end

  it "generates a UUID id" do
    expect(metric.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to ad_account" do
    expect(metric.ad_account).to eq(ad_account)
  end

  it "requires date" do
    metric.date = nil
    expect(metric).not_to be_valid
  end

  it "enforces date uniqueness scoped to ad_account" do
    duplicate = build(:ad_daily_metric, ad_account: ad_account, date: metric.date)
    expect(duplicate).not_to be_valid
  end

  it "allows same date for different accounts" do
    other_account = create(:ad_account)
    other_metric = build(:ad_daily_metric, ad_account: other_account, date: metric.date)
    expect(other_metric).to be_valid
  end

  it "validates spend is non-negative" do
    metric.spend = -1
    expect(metric).not_to be_valid
  end

  describe ".for_date_range" do
    it "returns metrics within the range" do
      create(:ad_daily_metric, ad_account: ad_account, date: 2.days.ago)
      create(:ad_daily_metric, ad_account: create(:ad_account), date: 30.days.ago)

      results = described_class.for_date_range(3.days.ago.to_date..Date.current)
      expect(results.count).to eq(1)
    end
  end
end
