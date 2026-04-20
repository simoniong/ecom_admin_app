require "rails_helper"

RSpec.describe "ShopifyWebhooks", type: :request do
  let(:store) { create(:shopify_store) }
  let(:secret) { "test-client-secret" }
  let(:order_payload) do
    {
      id: 12345, name: "#1001", email: "buyer@example.com",
      total_price: "49.99", currency: "USD",
      financial_status: "paid", fulfillment_status: "fulfilled",
      created_at: "2026-03-20",
      customer: { id: 100, email: "buyer@example.com", first_name: "Jane" },
      fulfillments: []
    }.to_json
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SHOPIFY_CLIENT_SECRET").and_return(secret)
  end

  def webhook_hmac(body)
    digest = OpenSSL::HMAC.digest("SHA256", secret, body)
    Base64.strict_encode64(digest)
  end

  def post_webhook(body:, topic: "orders/create", shop_domain: store.shop_domain, hmac: nil)
    hmac ||= webhook_hmac(body)
    post "/shopify/webhooks", params: body, headers: {
      "Content-Type" => "application/json",
      "X-Shopify-Topic" => topic,
      "X-Shopify-Shop-Domain" => shop_domain,
      "X-Shopify-Hmac-Sha256" => hmac
    }
  end

  describe "POST /shopify/webhooks" do
    it "returns 200 and enqueues job for orders/create" do
      expect {
        post_webhook(body: order_payload, topic: "orders/create")
      }.to have_enqueued_job(ProcessShopifyOrderWebhookJob).with(store.id, anything)

      expect(response).to have_http_status(:ok)
    end

    it "returns 200 and enqueues job for orders/updated" do
      expect {
        post_webhook(body: order_payload, topic: "orders/updated")
      }.to have_enqueued_job(ProcessShopifyOrderWebhookJob)

      expect(response).to have_http_status(:ok)
    end

    it "returns 200 for unknown topic without enqueuing" do
      expect {
        post_webhook(body: order_payload, topic: "products/create")
      }.not_to have_enqueued_job(ProcessShopifyOrderWebhookJob)

      expect(response).to have_http_status(:ok)
    end

    it "returns 401 for invalid HMAC" do
      post_webhook(body: order_payload, hmac: "invalid-hmac")
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 for missing HMAC" do
      post "/shopify/webhooks", params: order_payload, headers: {
        "Content-Type" => "application/json",
        "X-Shopify-Topic" => "orders/create",
        "X-Shopify-Shop-Domain" => store.shop_domain
      }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 when secret is not configured" do
      allow(ENV).to receive(:[]).with("SHOPIFY_CLIENT_SECRET").and_return(nil)
      allow(Rails.application.credentials).to receive(:dig).with(:shopify, :client_secret).and_return(nil)

      post "/shopify/webhooks", params: order_payload, headers: {
        "Content-Type" => "application/json",
        "X-Shopify-Topic" => "orders/create",
        "X-Shopify-Shop-Domain" => store.shop_domain,
        "X-Shopify-Hmac-Sha256" => "some-hmac"
      }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for unknown shop domain" do
      post_webhook(body: order_payload, shop_domain: "unknown.myshopify.com")
      expect(response).to have_http_status(:not_found)
    end

    context "GDPR mandatory webhooks" do
      let(:redact_payload) do
        {
          shop_id: 999,
          shop_domain: store.shop_domain,
          customer: { id: 5001, email: "privacy@example.com" },
          orders_to_redact: []
        }.to_json
      end

      it "returns 200 for customers/data_request and does not enqueue" do
        expect {
          post_webhook(body: redact_payload, topic: "customers/data_request")
        }.not_to have_enqueued_job

        expect(response).to have_http_status(:ok)
      end

      it "returns 200 and enqueues ProcessCustomerRedactJob for customers/redact" do
        expect {
          post_webhook(body: redact_payload, topic: "customers/redact")
        }.to have_enqueued_job(ProcessCustomerRedactJob).with(store.id, anything)

        expect(response).to have_http_status(:ok)
      end

      it "returns 200 and enqueues ProcessShopRedactJob for shop/redact" do
        expect {
          post_webhook(body: redact_payload, topic: "shop/redact")
        }.to have_enqueued_job(ProcessShopRedactJob).with(store.id)

        expect(response).to have_http_status(:ok)
      end

      it "returns 200 for shop/redact even when store is already deleted" do
        expect {
          post_webhook(body: redact_payload, topic: "shop/redact", shop_domain: "gone.myshopify.com")
        }.not_to have_enqueued_job(ProcessShopRedactJob)

        expect(response).to have_http_status(:ok)
      end

      it "returns 401 when HMAC is invalid for GDPR topics" do
        post_webhook(body: redact_payload, topic: "customers/redact", hmac: "bad-hmac")
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
