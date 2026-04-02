require "rails_helper"

RSpec.describe AdCampaignDailyMetric, type: :model do
  let(:campaign) { create(:ad_campaign) }
  let(:metric) { create(:ad_campaign_daily_metric, ad_campaign: campaign) }

  it "is valid with valid attributes" do
    expect(metric).to be_valid
  end

  it "generates a UUID id" do
    expect(metric.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to ad_campaign" do
    expect(metric.ad_campaign).to eq(campaign)
  end

  it "requires date" do
    metric.date = nil
    expect(metric).not_to be_valid
  end

  it "enforces date uniqueness scoped to ad_campaign" do
    duplicate = build(:ad_campaign_daily_metric, ad_campaign: campaign, date: metric.date)
    expect(duplicate).not_to be_valid
  end

  it "validates spend is not negative" do
    metric.spend = -1
    expect(metric).not_to be_valid
  end

  describe ".for_date_range" do
    it "returns metrics within the date range" do
      m1 = create(:ad_campaign_daily_metric, ad_campaign: campaign, date: 2.days.ago.to_date)
      m2 = create(:ad_campaign_daily_metric, ad_campaign: campaign, date: 5.days.ago.to_date)
      range = 3.days.ago.to_date..Date.current

      results = described_class.for_date_range(range)
      expect(results).to include(m1)
      expect(results).not_to include(m2)
    end
  end
end
