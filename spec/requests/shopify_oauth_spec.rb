require "rails_helper"

RSpec.describe "ShopifyOauth", type: :request do
  let(:user) { create(:user) }

  describe "GET /shopify/auth" do
    it "redirects unauthenticated user" do
      get shopify_auth_path, params: { shop: "test.myshopify.com" }
      expect(response).to redirect_to(new_user_session_path)
    end

    it "redirects to Shopify authorize URL" do
      sign_in user
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SHOPIFY_CLIENT_ID").and_return("test-client-id")

      get shopify_auth_path, params: { shop: "test.myshopify.com" }
      expect(response).to have_http_status(:redirect)
      expect(response.location).to include("test.myshopify.com/admin/oauth/authorize")
      expect(response.location).to include("test-client-id")
    end

    it "stores nonce in session" do
      sign_in user
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SHOPIFY_CLIENT_ID").and_return("test-client-id")

      get shopify_auth_path, params: { shop: "test.myshopify.com" }
      expect(session[:shopify_oauth_nonce]).to be_present
    end

    it "rejects invalid shop domain" do
      sign_in user
      get shopify_auth_path, params: { shop: "invalid-domain.com" }
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "rejects blank shop domain" do
      sign_in user
      get shopify_auth_path, params: { shop: "" }
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "redirects when client_id is missing" do
      sign_in user
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SHOPIFY_CLIENT_ID").and_return(nil)
      allow(Rails.application.credentials).to receive(:dig).with(:shopify, :client_id).and_return(nil)

      get shopify_auth_path, params: { shop: "test.myshopify.com" }
      expect(response).to redirect_to(shopify_stores_path)
    end
  end

  describe "GET /shopify/callback" do
    before do
      sign_in user
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SHOPIFY_CLIENT_ID").and_return("test-client-id")
      allow(ENV).to receive(:[]).with("SHOPIFY_CLIENT_SECRET").and_return("test-client-secret")
    end

    it "rejects missing code" do
      get shopify_callback_path, params: { shop: "test.myshopify.com", state: "nonce" }
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "rejects invalid shop domain" do
      get shopify_callback_path, params: { shop: "bad.com", code: "code", state: "nonce" }
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "rejects state mismatch" do
      # Set a nonce in session first
      get shopify_auth_path, params: { shop: "test.myshopify.com" }

      get shopify_callback_path, params: {
        shop: "test.myshopify.com", code: "test-code", state: "wrong-state", hmac: "abc"
      }
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "creates store on successful callback" do
      get shopify_auth_path, params: { shop: "test.myshopify.com" }
      nonce = session[:shopify_oauth_nonce]

      # Build valid HMAC
      params = { "code" => "test-code", "shop" => "test.myshopify.com", "state" => nonce }
      message = params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
      hmac = OpenSSL::HMAC.hexdigest("SHA256", "test-client-secret", message)

      # Mock token exchange
      stub_request(:post, "https://test.myshopify.com/admin/oauth/access_token")
        .to_return(
          status: 200,
          body: { access_token: "shpat_new_token", scope: "read_products,read_customers" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Mock shop timezone fetch
      stub_request(:get, %r{test\.myshopify\.com/admin/api/2024-10/shop\.json})
        .to_return(
          status: 200,
          body: { shop: { iana_timezone: "Asia/Macau" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect {
        get shopify_callback_path, params: params.merge("hmac" => hmac)
      }.to change(ShopifyStore, :count).by(1)

      store = user.shopify_stores.last
      expect(store.shop_domain).to eq("test.myshopify.com")
      expect(store.access_token).to eq("shpat_new_token")
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "enqueues order sync after successful store creation" do
      get shopify_auth_path, params: { shop: "test.myshopify.com" }
      nonce = session[:shopify_oauth_nonce]

      params = { "code" => "test-code", "shop" => "test.myshopify.com", "state" => nonce }
      message = params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
      hmac = OpenSSL::HMAC.hexdigest("SHA256", "test-client-secret", message)

      stub_request(:post, "https://test.myshopify.com/admin/oauth/access_token")
        .to_return(
          status: 200,
          body: { access_token: "shpat_new_token", scope: "read_products,read_customers" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, %r{test\.myshopify\.com/admin/api/2024-10/shop\.json})
        .to_return(
          status: 200,
          body: { shop: { iana_timezone: "Asia/Macau" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect {
        get shopify_callback_path, params: params.merge("hmac" => hmac)
      }.to have_enqueued_job(SyncAllShopifyOrdersJob)
        .and have_enqueued_job(RegisterShopifyWebhooksJob)
        .and have_enqueued_job(BackfillShopifyMetricsJob)
    end

    it "redirects on failed token exchange" do
      get shopify_auth_path, params: { shop: "test.myshopify.com" }
      nonce = session[:shopify_oauth_nonce]

      params = { "code" => "test-code", "shop" => "test.myshopify.com", "state" => nonce }
      message = params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
      hmac = OpenSSL::HMAC.hexdigest("SHA256", "test-client-secret", message)

      stub_request(:post, "https://test.myshopify.com/admin/oauth/access_token")
        .to_return(status: 400, body: "Bad Request")

      get shopify_callback_path, params: params.merge("hmac" => hmac)
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "shows already_bound error when store is bound by another user" do
      other_user = create(:user)
      create(:shopify_store, user: other_user, shop_domain: "test.myshopify.com")

      get shopify_auth_path, params: { shop: "test.myshopify.com" }
      nonce = session[:shopify_oauth_nonce]

      params = { "code" => "test-code", "shop" => "test.myshopify.com", "state" => nonce }
      message = params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
      hmac = OpenSSL::HMAC.hexdigest("SHA256", "test-client-secret", message)

      stub_request(:post, "https://test.myshopify.com/admin/oauth/access_token")
        .to_return(
          status: 200,
          body: { access_token: "shpat_new_token", scope: "read_products" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, %r{test\.myshopify\.com/admin/api/2024-10/shop\.json})
        .to_return(
          status: 200,
          body: { shop: { iana_timezone: "Asia/Macau" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      get shopify_callback_path, params: params.merge("hmac" => hmac)
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to eq(I18n.t("shopify_stores.already_bound"))
    end
  end
end
