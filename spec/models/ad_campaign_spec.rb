require "rails_helper"

RSpec.describe AdCampaign, type: :model do
  let(:user) { create(:user) }
  let(:ad_account) { create(:ad_account, user: user) }
  let(:campaign) { create(:ad_campaign, ad_account: ad_account) }

  it "is valid with valid attributes" do
    expect(campaign).to be_valid
  end

  it "generates a UUID id" do
    expect(campaign.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to ad_account" do
    expect(campaign.ad_account).to eq(ad_account)
  end

  it "requires campaign_id" do
    campaign.campaign_id = ""
    expect(campaign).not_to be_valid
  end

  it "enforces campaign_id uniqueness scoped to ad_account" do
    duplicate = build(:ad_campaign, ad_account: ad_account, campaign_id: campaign.campaign_id)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:campaign_id]).to include("has already been taken")
  end

  it "allows same campaign_id for different ad_accounts" do
    other_account = create(:ad_account, user: user)
    other_campaign = build(:ad_campaign, ad_account: other_account, campaign_id: campaign.campaign_id)
    expect(other_campaign).to be_valid
  end

  it "requires valid status" do
    campaign.status = "invalid"
    expect(campaign).not_to be_valid
  end

  it "accepts active, paused, deleted statuses" do
    %w[active paused deleted].each do |s|
      campaign.status = s
      expect(campaign).to be_valid
    end
  end

  describe ".active scope" do
    it "returns only active campaigns" do
      active = create(:ad_campaign, ad_account: ad_account, status: "active")
      create(:ad_campaign, ad_account: ad_account, status: "paused")
      expect(described_class.active).to eq([ active ])
    end
  end

  describe "associations" do
    it "has many ad_campaign_daily_metrics" do
      metric = create(:ad_campaign_daily_metric, ad_campaign: campaign)
      expect(campaign.ad_campaign_daily_metrics).to include(metric)
    end

    it "destroys associated metrics on destroy" do
      create(:ad_campaign_daily_metric, ad_campaign: campaign)
      expect { campaign.destroy }.to change(AdCampaignDailyMetric, :count).by(-1)
    end
  end

  describe "#aggregated_metrics" do
    let(:date_range) { 3.days.ago.to_date..Date.current }

    before do
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: 1.day.ago.to_date,
        impressions: 1000, clicks: 50, add_to_cart: 10, checkout_initiated: 5, purchases: 3, spend: 100, conversion_value: 300)
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: 2.days.ago.to_date,
        impressions: 2000, clicks: 100, add_to_cart: 20, checkout_initiated: 10, purchases: 6, spend: 200, conversion_value: 600)
    end

    it "sums metrics across date range" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.impressions).to eq(3000)
      expect(m.clicks).to eq(150)
      expect(m.add_to_cart).to eq(30)
      expect(m.checkout_initiated).to eq(15)
      expect(m.purchases).to eq(9)
      expect(m.spend).to eq(300)
      expect(m.conversion_value).to eq(900)
    end

    it "computes CTR" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.ctr).to eq(5.0)
    end

    it "computes CPC" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.cpc).to eq(2.0)
    end

    it "computes cost per ATC" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.cost_per_atc).to eq(10.0)
    end

    it "computes cost per checkout" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.cost_per_checkout).to eq(20.0)
    end

    it "computes cost per purchase" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.cost_per_purchase).to be_within(0.01).of(33.33)
    end

    it "computes ROAS" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.roas).to eq(3.0)
    end

    it "computes ATC/click rate" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.atc_click_rate).to eq(20.0)
    end

    it "computes checkout/ATC rate" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.checkout_atc_rate).to eq(50.0)
    end

    it "computes purchase/checkout rate" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.purchase_checkout_rate).to eq(60.0)
    end

    it "computes purchase/click rate" do
      m = campaign.aggregated_metrics(date_range)
      expect(m.purchase_click_rate).to eq(6.0)
    end

    it "returns zeros when no metrics exist" do
      new_campaign = create(:ad_campaign, ad_account: ad_account)
      m = new_campaign.aggregated_metrics(date_range)
      expect(m.impressions).to eq(0)
      expect(m.ctr).to eq(0)
      expect(m.roas).to eq(0)
    end
  end
end
