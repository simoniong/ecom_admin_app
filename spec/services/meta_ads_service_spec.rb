require "rails_helper"

RSpec.describe MetaAdsService do
  let(:ad_account) { create(:ad_account, access_token: "test-token", token_expires_at: 60.days.from_now) }
  let(:service) { described_class.new(ad_account) }

  describe "#sync_date_range" do
    it "creates daily metrics from insights" do
      graph = instance_double(Koala::Facebook::API)
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)

      allow(graph).to receive(:get_connections).and_return([
        {
          "date_start" => "2026-03-27",
          "spend" => "150.50",
          "impressions" => "5000",
          "clicks" => "200",
          "actions" => [
            { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "10" }
          ],
          "action_values" => [
            { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "750.00" }
          ]
        }
      ])

      expect {
        service.sync_date_range(Date.new(2026, 3, 27), Date.new(2026, 3, 27))
      }.to change(AdDailyMetric, :count).by(1)

      metric = ad_account.ad_daily_metrics.find_by(date: "2026-03-27")
      expect(metric.spend).to eq(150.50)
      expect(metric.impressions).to eq(5000)
      expect(metric.clicks).to eq(200)
      expect(metric.conversions).to eq(10)
      expect(metric.conversion_value).to eq(750.00)
    end

    it "updates existing metrics" do
      create(:ad_daily_metric, ad_account: ad_account, date: "2026-03-27", spend: 100)

      graph = instance_double(Koala::Facebook::API)
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)

      allow(graph).to receive(:get_connections).and_return([
        {
          "date_start" => "2026-03-27",
          "spend" => "200.00",
          "impressions" => "6000",
          "clicks" => "250",
          "actions" => nil,
          "action_values" => nil
        }
      ])

      expect {
        service.sync_date_range(Date.new(2026, 3, 27), Date.new(2026, 3, 27))
      }.not_to change(AdDailyMetric, :count)

      metric = ad_account.ad_daily_metrics.find_by(date: "2026-03-27")
      expect(metric.spend).to eq(200.00)
      expect(metric.conversions).to eq(0)
    end

    it "handles missing actions gracefully" do
      graph = instance_double(Koala::Facebook::API)
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)

      allow(graph).to receive(:get_connections).and_return([
        {
          "date_start" => "2026-03-27",
          "spend" => "50.00",
          "impressions" => "1000",
          "clicks" => "30",
          "actions" => nil,
          "action_values" => nil
        }
      ])

      service.sync_date_range(Date.new(2026, 3, 27), Date.new(2026, 3, 27))
      metric = ad_account.ad_daily_metrics.find_by(date: "2026-03-27")
      expect(metric.conversions).to eq(0)
      expect(metric.conversion_value).to eq(0)
    end
  end

  describe "#sync_campaigns" do
    let(:graph) { instance_double(Koala::Facebook::API) }

    before do
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)
    end

    it "creates campaigns from Meta API data" do
      allow(graph).to receive(:get_connections).and_return([
        {
          "id" => "camp_001",
          "name" => "Summer Sale",
          "effective_status" => "ACTIVE",
          "daily_budget" => "5000"
        },
        {
          "id" => "camp_002",
          "name" => "Winter Promo",
          "effective_status" => "PAUSED",
          "daily_budget" => "3000"
        }
      ])

      expect {
        service.sync_campaigns
      }.to change(AdCampaign, :count).by(2)

      campaign = ad_account.ad_campaigns.find_by(campaign_id: "camp_001")
      expect(campaign.campaign_name).to eq("Summer Sale")
      expect(campaign.status).to eq("active")
      expect(campaign.daily_budget).to eq(50.0)

      paused = ad_account.ad_campaigns.find_by(campaign_id: "camp_002")
      expect(paused.status).to eq("paused")
      expect(paused.daily_budget).to eq(30.0)
    end

    it "updates existing campaigns" do
      create(:ad_campaign, ad_account: ad_account, campaign_id: "camp_001", campaign_name: "Old Name", status: "active")

      allow(graph).to receive(:get_connections).and_return([
        {
          "id" => "camp_001",
          "name" => "New Name",
          "effective_status" => "PAUSED",
          "daily_budget" => "10000"
        }
      ])

      expect {
        service.sync_campaigns
      }.not_to change(AdCampaign, :count)

      campaign = ad_account.ad_campaigns.find_by(campaign_id: "camp_001")
      expect(campaign.campaign_name).to eq("New Name")
      expect(campaign.status).to eq("paused")
    end

    it "maps DELETED and ARCHIVED statuses" do
      allow(graph).to receive(:get_connections).and_return([
        { "id" => "camp_d", "name" => "Deleted", "effective_status" => "DELETED", "daily_budget" => "0" },
        { "id" => "camp_a", "name" => "Archived", "effective_status" => "ARCHIVED", "daily_budget" => "0" }
      ])

      service.sync_campaigns

      expect(ad_account.ad_campaigns.find_by(campaign_id: "camp_d").status).to eq("deleted")
      expect(ad_account.ad_campaigns.find_by(campaign_id: "camp_a").status).to eq("deleted")
    end
  end

  describe "#sync_campaign_insights" do
    let(:graph) { instance_double(Koala::Facebook::API) }
    let!(:campaign) { create(:ad_campaign, ad_account: ad_account, campaign_id: "camp_001") }

    before do
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)
      # stub campaigns fetch (used in sync_campaigns, not here directly)
      allow(graph).to receive(:get_connections).with(
        "camp_001", "insights", anything
      ).and_return([
        {
          "date_start" => "2026-03-27",
          "spend" => "100.50",
          "impressions" => "5000",
          "clicks" => "200",
          "actions" => [
            { "action_type" => "offsite_conversion.fb_pixel_add_to_cart", "value" => "30" },
            { "action_type" => "offsite_conversion.fb_pixel_initiate_checkout", "value" => "15" },
            { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "8" }
          ],
          "action_values" => [
            { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "600.00" }
          ]
        }
      ])
    end

    it "creates daily metrics for campaigns" do
      expect {
        service.sync_campaign_insights(Date.new(2026, 3, 27), Date.new(2026, 3, 27))
      }.to change(AdCampaignDailyMetric, :count).by(1)

      metric = campaign.ad_campaign_daily_metrics.find_by(date: "2026-03-27")
      expect(metric.impressions).to eq(5000)
      expect(metric.clicks).to eq(200)
      expect(metric.add_to_cart).to eq(30)
      expect(metric.checkout_initiated).to eq(15)
      expect(metric.purchases).to eq(8)
      expect(metric.spend).to eq(100.50)
      expect(metric.conversion_value).to eq(600.00)
    end

    it "updates existing campaign metrics" do
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: "2026-03-27", spend: 50)

      expect {
        service.sync_campaign_insights(Date.new(2026, 3, 27), Date.new(2026, 3, 27))
      }.not_to change(AdCampaignDailyMetric, :count)

      metric = campaign.ad_campaign_daily_metrics.find_by(date: "2026-03-27")
      expect(metric.spend).to eq(100.50)
    end

    it "handles API errors per campaign gracefully" do
      allow(graph).to receive(:get_connections).with(
        "camp_001", "insights", anything
      ).and_raise(Koala::Facebook::ClientError.new(400, "Rate limited"))

      expect { service.sync_campaign_insights(Date.new(2026, 3, 27), Date.new(2026, 3, 27)) }.not_to raise_error
    end
  end

  describe "#refresh_token_if_needed!" do
    it "refreshes token when expiring soon" do
      ad_account.update!(token_expires_at: 3.days.from_now)

      oauth = instance_double(Koala::Facebook::OAuth)
      allow(Koala::Facebook::OAuth).to receive(:new).and_return(oauth)
      allow(oauth).to receive(:exchange_access_token_info).and_return({
        "access_token" => "new-long-token",
        "expires_in" => 5_184_000
      })

      service.refresh_token_if_needed!

      ad_account.reload
      expect(ad_account.access_token).to eq("new-long-token")
      expect(ad_account.token_expires_at).to be > 50.days.from_now
    end

    it "does not refresh when token is not expiring soon" do
      ad_account.update!(token_expires_at: 30.days.from_now)

      expect(Koala::Facebook::OAuth).not_to receive(:new)
      service.refresh_token_if_needed!
    end

    it "does not refresh when token_expires_at is nil" do
      ad_account.update!(token_expires_at: nil)

      expect(Koala::Facebook::OAuth).not_to receive(:new)
      service.refresh_token_if_needed!
    end
  end
end
