require "rails_helper"

RSpec.describe "ShopifyOauth", type: :request do
  let(:user) { create(:user) }
  let(:client_id) { "merchant-client-id" }
  let(:client_secret) { "merchant-client-secret" }

  def auth_params(extra = {})
    { shop: "test.myshopify.com", client_id: client_id, client_secret: client_secret }.merge(extra)
  end

  describe "POST /shopify/auth" do
    it "redirects unauthenticated user" do
      post shopify_auth_path, params: auth_params
      expect(response).to redirect_to(new_user_session_path)
    end

    it "redirects to the Shopify authorize URL using the submitted client_id" do
      sign_in user
      post shopify_auth_path, params: auth_params
      expect(response).to have_http_status(:redirect)
      expect(response.location).to include("test.myshopify.com/admin/oauth/authorize")
      expect(response.location).to include("merchant-client-id")
    end

    it "stashes the nonce and pending credentials in the session" do
      sign_in user
      post shopify_auth_path, params: auth_params
      expect(session[:shopify_oauth_nonce]).to be_present
      expect(session[:shopify_pending_client_id]).to eq(client_id)
      expect(session[:shopify_pending_client_secret]).to eq(client_secret)
      expect(session[:shopify_pending_shop]).to eq("test.myshopify.com")
    end

    it "rejects an invalid shop domain" do
      sign_in user
      post shopify_auth_path, params: auth_params(shop: "invalid-domain.com")
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "rejects a blank shop domain" do
      sign_in user
      post shopify_auth_path, params: auth_params(shop: "")
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "rejects a missing client_id" do
      sign_in user
      post shopify_auth_path, params: auth_params(client_id: "")
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to be_present
    end

    it "rejects a missing client_secret" do
      sign_in user
      post shopify_auth_path, params: auth_params(client_secret: "")
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to be_present
    end

    context "when the company has groups" do
      let(:company) { user.companies.first }
      let!(:group) { create(:group, company: company, name: "Sales") }

      before { sign_in user }

      it "redirects with an alert when owner omits group_id" do
        post shopify_auth_path, params: auth_params
        expect(response).to redirect_to(shopify_stores_path)
        expect(flash[:alert]).to be_present
      end

      it "stores pending_binding_group_id when owner supplies group_id" do
        post shopify_auth_path, params: auth_params(group_id: group.id)
        expect(response.location).to include("test.myshopify.com/admin/oauth/authorize")
        expect(session[:pending_binding_group_id]).to eq(group.id)
      end
    end
  end

  describe "GET /shopify/callback" do
    before { sign_in user }

    # Drives #auth to populate the session the way the real flow does.
    def start_auth(extra = {})
      post shopify_auth_path, params: auth_params(extra)
      session[:shopify_oauth_nonce]
    end

    def signed_callback_params(nonce:, shop: "test.myshopify.com", code: "test-code")
      params = { "code" => code, "shop" => shop, "state" => nonce }
      message = params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
      hmac = OpenSSL::HMAC.hexdigest("SHA256", client_secret, message)
      params.merge("hmac" => hmac)
    end

    def stub_token_and_timezone
      stub_request(:post, "https://test.myshopify.com/admin/oauth/access_token")
        .to_return(
          status: 200,
          body: { access_token: "shpat_new_token", scope: "read_products,read_customers" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, %r{test\.myshopify\.com/admin/api/2024-10/shop\.json})
        .to_return(
          status: 200,
          body: { shop: { name: "Test Store", iana_timezone: "Asia/Macau" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "rejects a missing code" do
      nonce = start_auth
      get shopify_callback_path, params: { shop: "test.myshopify.com", state: nonce }
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "rejects an invalid shop domain" do
      nonce = start_auth
      get shopify_callback_path, params: { shop: "bad.com", code: "code", state: nonce }
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "redirects with oauth_failure when the session has no pending credentials" do
      # No start_auth call — session is empty
      get shopify_callback_path, params: { shop: "test.myshopify.com", code: "test-code", state: "nonce" }
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to eq(I18n.t("shopify_stores.oauth_failure"))
    end

    it "redirects with an alert when the callback shop differs from the session shop" do
      nonce = start_auth
      params = signed_callback_params(nonce: nonce, shop: "other.myshopify.com")
      get shopify_callback_path, params: params
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to be_present
    end

    it "rejects a state mismatch" do
      start_auth
      get shopify_callback_path, params: {
        shop: "test.myshopify.com", code: "test-code", state: "wrong-state", hmac: "abc"
      }
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to eq(I18n.t("shopify_stores.oauth_failure"))
    end

    it "creates the store with the submitted credentials on a successful callback" do
      nonce = start_auth
      stub_token_and_timezone

      expect {
        get shopify_callback_path, params: signed_callback_params(nonce: nonce)
      }.to change(ShopifyStore, :count).by(1)

      store = user.shopify_stores.last
      expect(store.shop_domain).to eq("test.myshopify.com")
      expect(store.access_token).to eq("shpat_new_token")
      expect(store.client_id).to eq(client_id)
      expect(store.client_secret).to eq(client_secret)
      expect(store.name).to eq("Test Store")
      expect(store.timezone).to eq("Asia/Macau")
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:notice]).to eq(I18n.t("shopify_stores.bind_success"))
    end

    it "clears the pending session values after a successful callback" do
      nonce = start_auth
      stub_token_and_timezone
      get shopify_callback_path, params: signed_callback_params(nonce: nonce)
      expect(session[:shopify_pending_client_id]).to be_nil
      expect(session[:shopify_pending_client_secret]).to be_nil
      expect(session[:shopify_pending_shop]).to be_nil
    end

    it "enqueues sync jobs after a successful store creation" do
      nonce = start_auth
      stub_token_and_timezone

      expect {
        get shopify_callback_path, params: signed_callback_params(nonce: nonce)
      }.to have_enqueued_job(SyncAllShopifyOrdersJob)
        .and have_enqueued_job(RegisterShopifyWebhooksJob)
        .and have_enqueued_job(BackfillShopifyMetricsJob)
    end

    it "redirects on a failed token exchange" do
      nonce = start_auth
      stub_request(:post, "https://test.myshopify.com/admin/oauth/access_token")
        .to_return(status: 400, body: "Bad Request")

      get shopify_callback_path, params: signed_callback_params(nonce: nonce)
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to eq(I18n.t("shopify_stores.bind_failure"))
    end

    it "shows already_bound when the store is bound by another user" do
      other_user = create(:user)
      create(:shopify_store, user: other_user, shop_domain: "test.myshopify.com")
      nonce = start_auth
      stub_token_and_timezone

      get shopify_callback_path, params: signed_callback_params(nonce: nonce)
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to eq(I18n.t("shopify_stores.already_bound"))
    end
  end
end
