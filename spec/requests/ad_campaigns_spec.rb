require "rails_helper"

RSpec.describe "AdCampaigns", type: :request do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user) }
  let(:ad_account) { create(:ad_account, user: user, shopify_store: store) }

  describe "GET /ad_campaigns" do
    it "returns success for authenticated user" do
      sign_in user
      get ad_campaigns_path
      expect(response).to have_http_status(:success)
    end

    it "redirects unauthenticated user" do
      get ad_campaigns_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "shows empty state when no campaigns" do
      sign_in user
      get ad_campaigns_path
      expect(response.body).to include("No ad campaigns found")
    end

    it "lists campaigns for the selected store" do
      campaign = create(:ad_campaign, ad_account: ad_account, campaign_name: "Summer Sale")
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: Date.current, impressions: 5000)

      sign_in user
      get ad_campaigns_path, params: { shopify_store_id: store.id }
      expect(response.body).to include("Summer Sale")
      expect(response.body).to include("5,000")
    end

    it "does not show other users campaigns" do
      other_user = create(:user)
      other_account = create(:ad_account, user: other_user)
      create(:ad_campaign, ad_account: other_account, campaign_name: "Secret Campaign")

      sign_in user
      get ad_campaigns_path
      expect(response.body).not_to include("Secret Campaign")
    end

    it "filters by ad account" do
      account1 = create(:ad_account, user: user, shopify_store: store, account_name: "Account 1")
      account2 = create(:ad_account, user: user, shopify_store: store, account_name: "Account 2")
      create(:ad_campaign, ad_account: account1, campaign_name: "Campaign A")
      create(:ad_campaign, ad_account: account2, campaign_name: "Campaign B")

      sign_in user
      get ad_campaigns_path, params: { shopify_store_id: store.id, ad_account_id: account1.id }
      expect(response.body).to include("Campaign A")
      expect(response.body).not_to include("Campaign B")
    end

    it "filters by date range" do
      campaign = create(:ad_campaign, ad_account: ad_account)
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: 3.days.ago.to_date, impressions: 1000)
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: 30.days.ago.to_date, impressions: 9999)

      sign_in user
      get ad_campaigns_path, params: { from_date: 5.days.ago.to_date, to_date: Date.current }
      expect(response.body).to include("1,000")
      expect(response.body).not_to include("9,999")
    end

    it "hides store dropdown when only one store" do
      create(:ad_campaign, ad_account: ad_account)
      sign_in user
      get ad_campaigns_path
      expect(response.body).not_to include("<select name=\"shopify_store_id\"")
    end

    it "shows store dropdown when multiple stores" do
      create(:shopify_store, user: user)
      create(:ad_campaign, ad_account: ad_account)
      sign_in user
      get ad_campaigns_path
      expect(response.body).to include("<select name=\"shopify_store_id\"")
    end

    it "shows campaign status badges" do
      create(:ad_campaign, ad_account: ad_account, status: "active")
      create(:ad_campaign, ad_account: ad_account, status: "paused")

      sign_in user
      get ad_campaigns_path
      expect(response.body).to include("Active")
      expect(response.body).to include("Paused")
    end

    it "sorts active campaigns before others" do
      paused = create(:ad_campaign, ad_account: ad_account, campaign_name: "AAA Paused", status: "paused")
      active = create(:ad_campaign, ad_account: ad_account, campaign_name: "ZZZ Active", status: "active")

      sign_in user
      get ad_campaigns_path
      body = response.body
      expect(body.index("ZZZ Active")).to be < body.index("AAA Paused")
    end

    it "shows date range quick pick buttons" do
      sign_in user
      get ad_campaigns_path
      expect(response.body).to include("Today")
      expect(response.body).to include("Last 7 Days")
      expect(response.body).to include("Maximum")
    end

    it "applies template column visibility" do
      template = create(:campaign_display_template, user: user, visible_columns: %w[impressions roas])
      create(:ad_campaign, ad_account: ad_account)

      sign_in user
      get ad_campaigns_path, params: { template_id: template.id }

      doc = Nokogiri::HTML(response.body)
      # Visible columns should not have the hidden class
      impressions_th = doc.at_css('thead th[data-column="impressions"]')
      roas_th = doc.at_css('thead th[data-column="roas"]')
      expect(impressions_th).to be_present
      expect(impressions_th["class"]).not_to include("hidden")
      expect(roas_th).to be_present
      expect(roas_th["class"]).not_to include("hidden")

      # Hidden columns should have the hidden class
      cpc_th = doc.at_css('thead th[data-column="cpc"]')
      cost_per_atc_th = doc.at_css('thead th[data-column="cost_per_atc"]')
      expect(cpc_th["class"]).to include("hidden")
      expect(cost_per_atc_th["class"]).to include("hidden")
    end

    it "shows all columns when no template selected" do
      create(:ad_campaign, ad_account: ad_account)

      sign_in user
      get ad_campaigns_path
      expect(response.body).to include("Impressions")
      expect(response.body).to include("CPC")
      expect(response.body).to include("ROAS")
    end

    it "shows template selector when templates exist" do
      create(:campaign_display_template, user: user, name: "My Template")

      sign_in user
      get ad_campaigns_path
      expect(response.body).to include("My Template")
    end

    it "filters by status" do
      create(:ad_campaign, ad_account: ad_account, campaign_name: "Active One", status: "active")
      create(:ad_campaign, ad_account: ad_account, campaign_name: "Paused One", status: "paused")

      sign_in user
      get ad_campaigns_path, params: { status_filter: "active" }
      expect(response.body).to include("Active One")
      expect(response.body).not_to include("Paused One")
    end

    it "filters by has_spend status showing campaigns with spend in date range" do
      active_camp = create(:ad_campaign, ad_account: ad_account, campaign_name: "Spent Campaign", status: "active")
      paused_camp = create(:ad_campaign, ad_account: ad_account, campaign_name: "Paused With Spend", status: "paused")
      no_spend_camp = create(:ad_campaign, ad_account: ad_account, campaign_name: "No Spend", status: "active")

      create(:ad_campaign_daily_metric, ad_campaign: active_camp, date: Date.current, spend: 100)
      create(:ad_campaign_daily_metric, ad_campaign: paused_camp, date: Date.current, spend: 50)
      create(:ad_campaign_daily_metric, ad_campaign: no_spend_camp, date: Date.current, spend: 0)

      sign_in user
      get ad_campaigns_path, params: { status_filter: "has_spend" }
      expect(response.body).to include("Spent Campaign")
      expect(response.body).to include("Paused With Spend")
      expect(response.body).not_to include("No Spend")
    end

    it "has_spend filter respects date range" do
      campaign = create(:ad_campaign, ad_account: ad_account, campaign_name: "Old Spend")
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: 30.days.ago.to_date, spend: 100)

      sign_in user
      get ad_campaigns_path, params: { status_filter: "has_spend", from_date: 3.days.ago.to_date, to_date: Date.current }
      expect(response.body).not_to include("Old Spend")
    end

    it "shows all statuses when no status filter" do
      create(:ad_campaign, ad_account: ad_account, campaign_name: "Active One", status: "active")
      create(:ad_campaign, ad_account: ad_account, campaign_name: "Paused One", status: "paused")

      sign_in user
      get ad_campaigns_path
      expect(response.body).to include("Active One")
      expect(response.body).to include("Paused One")
    end

    it "sorts by daily budget descending by default" do
      create(:ad_campaign, ad_account: ad_account, campaign_name: "Low Budget", status: "active", daily_budget: 10)
      create(:ad_campaign, ad_account: ad_account, campaign_name: "High Budget", status: "active", daily_budget: 100)

      sign_in user
      get ad_campaigns_path
      body = response.body
      expect(body.index("High Budget")).to be < body.index("Low Budget")
    end

    it "shows summary row when multiple campaigns" do
      c1 = create(:ad_campaign, ad_account: ad_account, status: "active")
      c2 = create(:ad_campaign, ad_account: ad_account, status: "active")
      create(:ad_campaign_daily_metric, ad_campaign: c1, date: Date.current, spend: 100, conversion_value: 300, impressions: 1000, clicks: 50, purchases: 5)
      create(:ad_campaign_daily_metric, ad_campaign: c2, date: Date.current, spend: 200, conversion_value: 600, impressions: 2000, clicks: 100, purchases: 10)

      sign_in user
      get ad_campaigns_path
      expect(response.body).to include("Summary")
      # Total spend $300, total conversion_value $900 => ROAS 3.0x
      expect(response.body).to include("3.0x")
    end

    it "hides summary row when only one campaign" do
      create(:ad_campaign, ad_account: ad_account)

      sign_in user
      get ad_campaigns_path
      expect(response.body).not_to include("Summary")
    end

    it "sorts by daily budget ascending when requested" do
      create(:ad_campaign, ad_account: ad_account, campaign_name: "Low Budget", status: "active", daily_budget: 10)
      create(:ad_campaign, ad_account: ad_account, campaign_name: "High Budget", status: "active", daily_budget: 100)

      sign_in user
      get ad_campaigns_path, params: { sort_column: "daily_budget", sort_direction: "asc" }
      body = response.body
      expect(body.index("Low Budget")).to be < body.index("High Budget")
    end

    it "sorts by metric column (spend)" do
      c1 = create(:ad_campaign, ad_account: ad_account, campaign_name: "Low Spend", status: "active")
      c2 = create(:ad_campaign, ad_account: ad_account, campaign_name: "High Spend", status: "active")
      create(:ad_campaign_daily_metric, ad_campaign: c1, date: Date.current, spend: 50)
      create(:ad_campaign_daily_metric, ad_campaign: c2, date: Date.current, spend: 500)

      sign_in user
      get ad_campaigns_path, params: { sort_column: "spend", sort_direction: "desc" }
      body = response.body
      expect(body.index("High Spend")).to be < body.index("Low Spend")
    end

    it "handles invalid date gracefully" do
      sign_in user
      get ad_campaigns_path, params: { from_date: "not-a-date" }
      expect(response).to have_http_status(:success)
    end

    it "keeps active campaigns first regardless of sort" do
      active = create(:ad_campaign, ad_account: ad_account, campaign_name: "Active Low", status: "active", daily_budget: 10)
      paused = create(:ad_campaign, ad_account: ad_account, campaign_name: "Paused High", status: "paused", daily_budget: 999)

      sign_in user
      get ad_campaigns_path, params: { sort_column: "daily_budget", sort_direction: "desc" }
      body = response.body
      expect(body.index("Active Low")).to be < body.index("Paused High")
    end
  end

  describe "POST /ad_campaigns/sync" do
    it "enqueues SyncAdCampaignsJob and redirects" do
      sign_in user
      expect {
        post sync_ad_campaigns_path
      }.to have_enqueued_job(SyncAdCampaignsJob)
      expect(response).to redirect_to(ad_campaigns_path)
      expect(flash[:notice]).to eq(I18n.t("ad_campaigns.sync_enqueued"))
    end

    it "redirects unauthenticated user" do
      post sync_ad_campaigns_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
