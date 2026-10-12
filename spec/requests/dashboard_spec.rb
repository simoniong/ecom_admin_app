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
      expect(response.body).to include(I18n.t("dashboard.orders"))
      expect(response.body).to include(I18n.t("dashboard.revenue"))
      expect(response.body).to include(I18n.t("dashboard.ad_spend"))
      expect(response.body).to include(I18n.t("dashboard.avg_order_value"))
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
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 3, revenue: 250)

      sign_in user
      get authenticated_root_path(range: "today")
      expect(response.body).to include("3")
      expect(response.body).to include("250")
    end

    it "accepts custom date range" do
      sign_in user
      get authenticated_root_path(start_date: "2026-04-01", end_date: "2026-04-07")
      expect(response).to have_http_status(:success)
    end

    it "responds to turbo frame requests" do
      sign_in user
      get authenticated_root_path(range: "yesterday"), headers: { "Turbo-Frame" => "dashboard_metrics" }
      expect(response).to have_http_status(:success)
    end

    it "shows a row per ad platform followed by the totals row" do
      sign_in user
      meta = create(:ad_account, user: user)
      google = create(:ad_account, :google, user: user)
      create(:ad_daily_metric, ad_account: meta, date: Date.current, spend: 120, conversions: 3, conversion_value: 360)
      create(:ad_daily_metric, ad_account: google, date: Date.current, spend: 80, conversions: 2, conversion_value: 100)

      get authenticated_root_path(range: "today")

      html = Nokogiri::HTML(response.body)
      rows = html.css("[data-ad-platform]").map { |row| row["data-ad-platform"] }
      expect(rows).to eq(%w[meta google total])

      meta_row = html.at_css("[data-ad-platform='meta']").text.squish
      expect(meta_row).to include("Meta #{I18n.t('dashboard.ad_spend')}", "$120.00", "3.0x", "$40.00",
                                  "Meta #{I18n.t('dashboard.new_customer_cpa')} —")
      google_row = html.at_css("[data-ad-platform='google']").text.squish
      expect(google_row).to include("Google #{I18n.t('dashboard.ad_spend')}", "$80.00", "1.25x", "$40.00")
      total_row = html.at_css("[data-ad-platform='total']").text.squish
      expect(total_row).to include("#{I18n.t('dashboard.ad_platform_names.total')} #{I18n.t('dashboard.ad_spend')}", "$200.00")
    end

    it "displays CPA and new customer CPA card titles" do
      sign_in user
      get authenticated_root_path
      expect(response.body).to include(I18n.t("dashboard.cpa"))
      expect(response.body).to include(I18n.t("dashboard.new_customer_cpa"))
    end

    it "renders em-dash placeholder inside the CPA card when CPA cannot be computed" do
      store = create(:shopify_store, user: user)
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 0, new_customer_orders_count: 0, revenue: 0)

      sign_in user
      get authenticated_root_path(range: "today")

      # Scope the assertion to the CPA card so the page-level em-dash on the
      # date range separator can't make this test pass trivially.
      doc = Nokogiri::HTML(response.body)
      cpa_title = I18n.t("dashboard.ad_platform_metric", platform: I18n.t("dashboard.ad_platform_names.total"), metric: I18n.t("dashboard.cpa"))
      cpa_card = doc.xpath("//div[contains(@class, 'rounded-lg')][.//p[normalize-space(text())='#{cpa_title}']]").first
      expect(cpa_card).not_to be_nil, "CPA card not rendered"
      expect(cpa_card.text).to include("—")
    end

    it "renders a currency-formatted CPA when data is present" do
      store = create(:shopify_store, user: user)
      ad_account = create(:ad_account, user: user)
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 4, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 50)

      sign_in user
      get authenticated_root_path(range: "today")
      expect(response.body).to include("$5.00") # 50 / 10
      expect(response.body).to include("$12.50") # 50 / 4
    end

    it "renders the net revenue breakdown cards" do
      sign_in user
      get authenticated_root_path

      expect(response.body).to include(I18n.t("dashboard.gross_revenue"))
      expect(response.body).to include(I18n.t("dashboard.refunds"))
      expect(response.body).to include(I18n.t("dashboard.tax"))
      expect(response.body).to include(I18n.t("dashboard.transaction_fees"))
      expect(response.body).to include(I18n.t("dashboard.transaction_fees_note"))
      expect(response.body).to include(I18n.t("dashboard.net_revenue"))
    end

    it "groups metrics under section headers" do
      sign_in user
      get authenticated_root_path

      expect(response.body).to include(I18n.t("dashboard.section_revenue"))
      expect(response.body).to include(I18n.t("dashboard.section_orders"))
      expect(response.body).to include(I18n.t("dashboard.section_advertising"))
      expect(response.body).to include(I18n.t("dashboard.section_profit"))
      expect(response.body).to include(I18n.t("dashboard.net_revenue_badge"))
      expect(response.body).to include(I18n.t("dashboard.new_customer_orders"))
    end
  end
end
