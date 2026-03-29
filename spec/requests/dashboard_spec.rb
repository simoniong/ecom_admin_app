require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  let(:user) { create(:user) }

  describe "GET / (authenticated root)" do
    it "returns success for authenticated user" do
      sign_in user
      get authenticated_root_path
      expect(response).to have_http_status(:success)
    end

    it "displays metric cards" do
      sign_in user
      get authenticated_root_path
      expect(response.body).to include(I18n.t("dashboard.sessions"))
      expect(response.body).to include(I18n.t("dashboard.orders"))
      expect(response.body).to include(I18n.t("dashboard.revenue"))
      expect(response.body).to include(I18n.t("dashboard.conversion_rate"))
      expect(response.body).to include(I18n.t("dashboard.ad_spend"))
      expect(response.body).to include(I18n.t("dashboard.roas"))
    end

    it "displays date range buttons" do
      sign_in user
      get authenticated_root_path
      expect(response.body).to include(I18n.t("dashboard.ranges.today"))
      expect(response.body).to include(I18n.t("dashboard.ranges.yesterday"))
      expect(response.body).to include(I18n.t("dashboard.ranges.past_7_days"))
    end

    it "defaults to past_7_days range" do
      sign_in user
      get authenticated_root_path
      # The past_7_days button should have active styling
      expect(response.body).to include("past_7_days")
    end

    it "accepts range parameter" do
      sign_in user
      get authenticated_root_path(range: "today")
      expect(response).to have_http_status(:success)
    end

    it "displays metrics data from database" do
      store = create(:shopify_store, user: user)
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 42, orders_count: 3, revenue: 250)

      sign_in user
      get authenticated_root_path(range: "today")
      expect(response.body).to include("42")
      expect(response.body).to include("250")
    end

    it "responds to turbo frame requests" do
      sign_in user
      get authenticated_root_path(range: "yesterday"), headers: { "Turbo-Frame" => "dashboard_metrics" }
      expect(response).to have_http_status(:success)
    end
  end
end
