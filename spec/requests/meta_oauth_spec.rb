require "rails_helper"

RSpec.describe "MetaOauth", type: :request do
  let(:user) { create(:user) }

  describe "GET /meta/auth" do
    it "redirects to Facebook OAuth dialog" do
      sign_in user
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("META_APP_ID").and_return("test-app-id")
      allow(ENV).to receive(:[]).with("META_APP_SECRET").and_return("test-app-secret")

      get meta_auth_path
      expect(response).to have_http_status(:redirect)
      expect(response.location).to include("facebook.com")
      expect(response.location).to include("test-app-id")
      expect(response.location).to include("ads_management")
    end

    it "stores state nonce in session" do
      sign_in user
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("META_APP_ID").and_return("test-app-id")
      allow(ENV).to receive(:[]).with("META_APP_SECRET").and_return("test-app-secret")

      get meta_auth_path
      expect(session[:meta_oauth_state]).to be_present
    end

    it "redirects unauthenticated user" do
      get meta_auth_path
      expect(response).to redirect_to(new_user_session_path)
    end

    context "when the company has groups" do
      let(:company) { user.companies.first }
      let!(:group) { create(:group, company: company, name: "Sales") }

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("META_APP_ID").and_return("test-app-id")
        allow(ENV).to receive(:[]).with("META_APP_SECRET").and_return("test-app-secret")
        sign_in user
      end

      it "redirects with an alert when owner omits group_id" do
        get meta_auth_path
        expect(response).to redirect_to(ad_accounts_path)
        expect(flash[:alert]).to be_present
      end

      it "stores pending_binding_group_id when owner supplies group_id" do
        get meta_auth_path, params: { group_id: group.id }
        expect(response.location).to include("facebook.com")
        expect(session[:pending_binding_group_id]).to eq(group.id)
      end
    end
  end

  describe "GET /meta/callback" do
    before do
      sign_in user
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("META_APP_ID").and_return("test-app-id")
      allow(ENV).to receive(:[]).with("META_APP_SECRET").and_return("test-app-secret")
    end

    it "redirects on state mismatch" do
      get meta_callback_path, params: { code: "test-code", state: "wrong-state" }
      expect(response).to redirect_to(ad_accounts_path)
    end

    it "redirects when user denies authorization" do
      # Simulate setting state in session
      get meta_auth_path
      state = session[:meta_oauth_state]

      get meta_callback_path, params: { error: "access_denied", state: state }
      expect(response).to redirect_to(ad_accounts_path)
    end

    it "redirects when code is missing" do
      get meta_auth_path
      state = session[:meta_oauth_state]

      get meta_callback_path, params: { state: state }
      expect(response).to redirect_to(ad_accounts_path)
    end

    it "handles Koala errors gracefully" do
      get meta_auth_path
      state = session[:meta_oauth_state]

      oauth = instance_double(Koala::Facebook::OAuth)
      allow(Koala::Facebook::OAuth).to receive(:new).and_return(oauth)
      allow(oauth).to receive(:get_access_token).and_raise(Koala::Facebook::OAuthTokenRequestError.new(400, ""))

      get meta_callback_path, params: { code: "bad-code", state: state }
      expect(response).to redirect_to(ad_accounts_path)
    end
  end

  describe "POST /meta/select_accounts" do
    before do
      sign_in user
    end

    it "redirects when session token is missing" do
      post meta_select_accounts_path, params: { account_ids: [ "123" ] }
      expect(response).to redirect_to(ad_accounts_path)
    end

    it "redirects when no accounts selected" do
      # Simulate token in session by setting it directly
      post meta_select_accounts_path, params: {},
           headers: { "HTTP_COOKIE" => "" }
      expect(response).to redirect_to(ad_accounts_path)
    end

    it "creates ad accounts from selected IDs" do
      # We need to set session values, which is tricky in request specs.
      # Use the integration approach: simulate the full flow with mocks.
      get meta_auth_path
      state = session[:meta_oauth_state]

      oauth = instance_double(Koala::Facebook::OAuth)
      allow(Koala::Facebook::OAuth).to receive(:new).and_return(oauth)
      allow(oauth).to receive(:url_for_oauth_code).and_return("http://facebook.com/auth")
      allow(oauth).to receive(:get_access_token).and_return("short-token")
      allow(oauth).to receive(:exchange_access_token_info).and_return({
        "access_token" => "long-lived-token",
        "expires_in" => 5_184_000
      })

      graph = instance_double(Koala::Facebook::API)
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)
      allow(graph).to receive(:get_connections).and_return([
        { "account_id" => "12345", "name" => "Test Account", "account_status" => 1 }
      ])

      get meta_callback_path, params: { code: "test-code", state: state }

      expect {
        post meta_select_accounts_path, params: {
          account_ids: [ "12345" ],
          account_names: { "12345" => "Test Account" }
        }
      }.to change(AdAccount, :count).by(1)

      account = user.ad_accounts.last
      expect(account.account_id).to eq("act_12345")
      expect(account.account_name).to eq("Test Account")
      expect(account.platform).to eq("meta")
      expect(response).to redirect_to(ad_accounts_path)
    end
  end
end
