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
