require "rails_helper"

RSpec.describe "GoogleAdsOauth", type: :request do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }
  let(:base) { GoogleAdsApi::BASE_URL }

  before do
    sign_in user
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GOOGLE_CLIENT_ID").and_return("client-id")
    allow(ENV).to receive(:[]).with("GOOGLE_CLIENT_SECRET").and_return("client-secret")
    allow(ENV).to receive(:[]).with("GOOGLE_ADS_DEVELOPER_TOKEN").and_return("dev-token")
  end

  def json(body)
    { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  # Code exchange, token refresh and account discovery for a user who
  # reaches one client account through the Ksun Solution MCC.
  def stub_google(clients:)
    stub_request(:post, GoogleAdsApi::TOKEN_URL)
      .with(body: hash_including("grant_type" => "authorization_code"))
      .to_return(json(access_token: "a", refresh_token: "refresh-new"))
    stub_request(:post, GoogleAdsApi::TOKEN_URL)
      .with(body: hash_including("grant_type" => "refresh_token"))
      .to_return(json(access_token: "a"))
    stub_request(:get, "#{base}/customers:listAccessibleCustomers").to_return(json(resourceNames: [ "customers/6996886629" ]))
    stub_request(:post, "#{base}/customers/6996886629/googleAds:search")
      .with { |req| !JSON.parse(req.body)["query"].include?("customer_client") }
      .to_return(json(results: [ { customer: { id: "6996886629", manager: true } } ]))
    stub_request(:post, "#{base}/customers/6996886629/googleAds:search")
      .with { |req| JSON.parse(req.body)["query"].include?("customer_client") }
      .to_return(json(results: clients.map { |c| { customerClient: c } }))
  end

  def start_flow
    get google_ads_auth_path
    session[:google_ads_oauth_state]
  end

  describe "GET /google_ads/auth" do
    it "redirects to Google's consent screen with a state nonce" do
      get google_ads_auth_path

      expect(response).to redirect_to(%r{\Ahttps://accounts\.google\.com/o/oauth2/v2/auth\?})
      expect(response.location).to include("state=#{session[:google_ads_oauth_state]}")
      expect(response.location).to include(CGI.escape("http://www.example.com/google_ads/callback"))
    end

    context "when the company has groups" do
      let!(:group) { create(:group, company: company, name: "Sales") }

      it "requires a department" do
        get google_ads_auth_path

        expect(response).to redirect_to(ad_accounts_path)
        expect(flash[:alert]).to eq(I18n.t("ad_accounts.group_required"))
      end

      it "remembers the chosen department" do
        get google_ads_auth_path, params: { group_id: group.id }

        expect(session[:pending_binding_group_id]).to eq(group.id)
      end
    end
  end

  describe "GET /google_ads/callback" do
    it "rejects a state mismatch" do
      start_flow
      get google_ads_callback_path, params: { code: "c", state: "wrong" }

      expect(response).to redirect_to(ad_accounts_path)
      expect(flash[:alert]).to eq(I18n.t("ad_accounts.google_oauth_failure"))
    end

    it "handles the user declining consent" do
      state = start_flow
      get google_ads_callback_path, params: { error: "access_denied", state: state }

      expect(response).to redirect_to(ad_accounts_path)
    end

    it "lists the accounts under the manager account, active ones checked" do
      stub_google(clients: [
        { id: "5228314437", descriptiveName: "paintkitstudio", timeZone: "America/New_York", currencyCode: "USD", status: "ENABLED" },
        { id: "5000000001", descriptiveName: "Old shop", timeZone: "America/New_York", currencyCode: "USD", status: "CANCELED" }
      ])
      state = start_flow

      get google_ads_callback_path, params: { code: "c", state: state }

      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.text).to include("paintkitstudio", "522-831-4437", "Old shop")
      expect(page.at_css("#google_account_5228314437")["checked"]).to be_present
      expect(page.at_css("#google_account_5000000001")["checked"]).to be_nil
      expect(session[:google_ads_refresh_token]).to eq("refresh-new")
    end

    it "explains when no ad accounts are reachable" do
      stub_google(clients: [])
      state = start_flow

      get google_ads_callback_path, params: { code: "c", state: state }

      expect(response).to redirect_to(ad_accounts_path)
      expect(flash[:alert]).to eq(I18n.t("ad_accounts.google_no_accounts"))
    end

    it "fails gracefully when the code exchange fails" do
      stub_request(:post, GoogleAdsApi::TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)
      state = start_flow

      get google_ads_callback_path, params: { code: "c", state: state }

      expect(response).to redirect_to(ad_accounts_path)
      expect(flash[:alert]).to eq(I18n.t("ad_accounts.google_oauth_failure"))
    end
  end

  describe "POST /google_ads/select_accounts" do
    def authorize!
      stub_google(clients: [ { id: "5228314437", descriptiveName: "paintkitstudio", timeZone: "America/New_York", currencyCode: "USD", status: "ENABLED" } ])
      get google_ads_callback_path, params: { code: "c", state: start_flow }
    end

    let(:selection) do
      {
        account_ids: [ "5228314437" ],
        account_names: { "5228314437" => "paintkitstudio" },
        account_timezones: { "5228314437" => "America/New_York" },
        account_login_ids: { "5228314437" => "6996886629" }
      }
    end

    it "connects the selected accounts and queues a history backfill" do
      authorize!

      expect { post google_ads_select_accounts_path, params: selection }
        .to have_enqueued_job(SyncGoogleAdMetricsJob).with(hash_including(days: GoogleAdsOauthController::BACKFILL_DAYS))

      account = company.ad_accounts.find_by!(platform: "google", account_id: "5228314437")
      expect(account).to have_attributes(account_name: "paintkitstudio", timezone: "America/New_York",
                                         login_customer_id: "6996886629", access_token: "refresh-new",
                                         token_expires_at: nil, user: user)
      expect(response).to redirect_to(ad_accounts_path)
      expect(session[:google_ads_refresh_token]).to be_nil
    end

    it "reconnects an existing account in place with the new token" do
      existing = create(:ad_account, :google, user: user, company: company, account_id: "5228314437",
                                              access_token: "old", token_expires_at: 1.day.ago)
      authorize!

      post google_ads_select_accounts_path, params: selection

      expect(existing.reload).to have_attributes(access_token: "refresh-new", token_expires_at: nil)
      expect(company.ad_accounts.google.count).to eq(1)
    end

    it "drops malformed ids and falls back to UTC for an unknown timezone" do
      authorize!

      post google_ads_select_accounts_path, params: selection.merge(
        account_ids: [ "5228314437", "act_1; DROP" ],
        account_timezones: { "5228314437" => "Mars/Base" },
        account_login_ids: { "5228314437" => "not-a-number" }
      )

      expect(company.ad_accounts.google.pluck(:account_id)).to eq([ "5228314437" ])
      expect(company.ad_accounts.google.first).to have_attributes(timezone: "UTC", login_customer_id: nil)
    end

    it "requires a selection" do
      authorize!

      post google_ads_select_accounts_path, params: { account_ids: [] }

      expect(response).to redirect_to(ad_accounts_path)
      expect(flash[:alert]).to eq(I18n.t("ad_accounts.no_accounts_selected"))
    end

    it "refuses without an authorized session" do
      post google_ads_select_accounts_path, params: selection

      expect(response).to redirect_to(ad_accounts_path)
      expect(flash[:alert]).to eq(I18n.t("ad_accounts.google_oauth_failure"))
      expect(company.ad_accounts.google).to be_empty
    end
  end

  it "shows a Connect Google Ads button on the ad accounts page" do
    get ad_accounts_path

    button = Nokogiri::HTML(response.body).at_css("button[formaction='#{google_ads_auth_path}']")
    expect(button.text).to include(I18n.t("ad_accounts.connect_google"))
  end
end
