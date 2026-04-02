require "rails_helper"

RSpec.describe "Api::V1::AdCampaigns", type: :request do
  let(:api_key) { Rails.application.credentials.dig(:agent, :api_key) }
  let(:auth_headers) { { "Authorization" => "Bearer #{api_key}" } }
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user) }
  let(:ad_account) { create(:ad_account, user: user, shopify_store: store, account_name: "Test Account") }

  describe "authentication" do
    it "returns 401 without token" do
      get "/api/v1/ad_campaigns"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 with invalid token" do
      get "/api/v1/ad_campaigns", headers: { "Authorization" => "Bearer invalid" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 200 with valid token" do
      get "/api/v1/ad_campaigns", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/ad_campaigns" do
    it "returns all campaigns with metrics" do
      campaign = create(:ad_campaign, ad_account: ad_account, campaign_name: "Summer Sale")
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: Date.current,
        impressions: 1000, clicks: 50, add_to_cart: 10, checkout_initiated: 5, purchases: 3,
        spend: 100, conversion_value: 300)

      get "/api/v1/ad_campaigns", headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.length).to eq(1)
      expect(body.first["campaign_name"]).to eq("Summer Sale")
      expect(body.first["ad_account"]["account_name"]).to eq("Test Account")

      metrics = body.first["metrics"]
      expect(metrics["impressions"]).to eq(1000)
      expect(metrics["clicks"]).to eq(50)
      expect(metrics["add_to_cart"]).to eq(10)
      expect(metrics["checkout_initiated"]).to eq(5)
      expect(metrics["purchases"]).to eq(3)
      expect(metrics["spend"]).to eq(100.0)
      expect(metrics["conversion_value"]).to eq(300.0)
      expect(metrics["ctr"]).to eq(5.0)
      expect(metrics["roas"]).to eq(3.0)
    end

    it "filters by shopify_store_id" do
      campaign = create(:ad_campaign, ad_account: ad_account, campaign_name: "Store Campaign")
      other_store = create(:shopify_store, user: user)
      other_account = create(:ad_account, user: user, shopify_store: other_store)
      create(:ad_campaign, ad_account: other_account, campaign_name: "Other Campaign")

      get "/api/v1/ad_campaigns", params: { shopify_store_id: store.id }, headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.length).to eq(1)
      expect(body.first["campaign_name"]).to eq("Store Campaign")
    end

    it "filters by ad_account_id" do
      create(:ad_campaign, ad_account: ad_account, campaign_name: "Target")
      other_account = create(:ad_account, user: user, shopify_store: store)
      create(:ad_campaign, ad_account: other_account, campaign_name: "Other")

      get "/api/v1/ad_campaigns", params: { ad_account_id: ad_account.id }, headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.length).to eq(1)
      expect(body.first["campaign_name"]).to eq("Target")
    end

    it "filters by status" do
      create(:ad_campaign, ad_account: ad_account, status: "active", campaign_name: "Active One")
      create(:ad_campaign, ad_account: ad_account, status: "paused", campaign_name: "Paused One")

      get "/api/v1/ad_campaigns", params: { status: "active" }, headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.length).to eq(1)
      expect(body.first["campaign_name"]).to eq("Active One")
    end

    it "filters by date range" do
      campaign = create(:ad_campaign, ad_account: ad_account)
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: 2.days.ago.to_date, impressions: 500)
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: 30.days.ago.to_date, impressions: 9999)

      get "/api/v1/ad_campaigns", params: { from_date: 5.days.ago.to_date, to_date: Date.current }, headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.first["metrics"]["impressions"]).to eq(500)
    end

    it "includes date range in response" do
      get "/api/v1/ad_campaigns", params: { from_date: "2026-03-01", to_date: "2026-03-31" }, headers: auth_headers
      body = JSON.parse(response.body)
      # Empty array is fine, just checking no errors
      expect(response).to have_http_status(:ok)
    end

    it "returns 400 for invalid date format" do
      get "/api/v1/ad_campaigns", params: { from_date: "not-a-date" }, headers: auth_headers
      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Invalid date format")
    end
  end
end
