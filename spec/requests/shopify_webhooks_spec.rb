require "rails_helper"

RSpec.describe "ShopifyWebhooks", type: :request do
  let(:store) { create(:shopify_store) }
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

  def webhook_hmac(body, secret)
    Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, body))
  end

  def post_webhook(body:, secret:, topic: "orders/create", shop_domain: store.shop_domain, hmac: nil)
    hmac ||= webhook_hmac(body, secret)
    post "/shopify/webhooks", params: body, headers: {
      "Content-Type" => "application/json",
      "X-Shopify-Topic" => topic,
      "X-Shopify-Shop-Domain" => shop_domain,
      "X-Shopify-Hmac-Sha256" => hmac
    }
  end

  describe "POST /shopify/webhooks" do
    it "verifies HMAC with the store's own client_secret and enqueues for orders/create" do
      expect {
        post_webhook(body: order_payload, secret: store.client_secret, topic: "orders/create")
      }.to have_enqueued_job(ProcessShopifyOrderWebhookJob).with(store.id, anything)

      expect(response).to have_http_status(:ok)
    end

    it "enqueues for orders/updated" do
      expect {
        post_webhook(body: order_payload, secret: store.client_secret, topic: "orders/updated")
      }.to have_enqueued_job(ProcessShopifyOrderWebhookJob)

      expect(response).to have_http_status(:ok)
    end

    it "returns 200 for an unknown topic without enqueuing" do
      expect {
        post_webhook(body: order_payload, secret: store.client_secret, topic: "products/create")
      }.not_to have_enqueued_job(ProcessShopifyOrderWebhookJob)

      expect(response).to have_http_status(:ok)
    end

    it "returns 401 when the HMAC does not match the store's client_secret" do
      post_webhook(body: order_payload, secret: "wrong-secret", topic: "orders/create")
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 when the HMAC header is missing" do
      post "/shopify/webhooks", params: order_payload, headers: {
        "Content-Type" => "application/json",
        "X-Shopify-Topic" => "orders/create",
        "X-Shopify-Shop-Domain" => store.shop_domain
      }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for an unknown shop domain on a non-GDPR topic" do
      expect {
        post_webhook(body: order_payload, secret: "any-secret",
                     topic: "orders/create", shop_domain: "unknown.myshopify.com")
      }.not_to have_enqueued_job(ProcessShopifyOrderWebhookJob)

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

      it "returns 200 for customers/data_request without enqueuing" do
        expect {
          post_webhook(body: redact_payload, secret: store.client_secret, topic: "customers/data_request")
        }.not_to have_enqueued_job

        expect(response).to have_http_status(:ok)
      end

      it "enqueues ProcessCustomerRedactJob for customers/redact on a known store" do
        expect {
          post_webhook(body: redact_payload, secret: store.client_secret, topic: "customers/redact")
        }.to have_enqueued_job(ProcessCustomerRedactJob).with(store.id, anything)

        expect(response).to have_http_status(:ok)
      end

      it "enqueues ProcessShopRedactJob for shop/redact on a known store" do
        expect {
          post_webhook(body: redact_payload, secret: store.client_secret, topic: "shop/redact")
        }.to have_enqueued_job(ProcessShopRedactJob).with(store.id)

        expect(response).to have_http_status(:ok)
      end

      it "returns 200 for shop/redact for an unknown shop and skips HMAC" do
        expect {
          post_webhook(body: redact_payload, secret: "any-secret",
                       topic: "shop/redact", shop_domain: "gone.myshopify.com")
        }.not_to have_enqueued_job(ProcessShopRedactJob)

        expect(response).to have_http_status(:ok)
      end

      it "returns 200 for customers/redact for an unknown shop and skips HMAC" do
        expect {
          post_webhook(body: redact_payload, secret: "any-secret",
                       topic: "customers/redact", shop_domain: "gone.myshopify.com")
        }.not_to have_enqueued_job(ProcessCustomerRedactJob)

        expect(response).to have_http_status(:ok)
      end

      it "returns 401 for a known store when the HMAC is invalid on a GDPR topic" do
        post_webhook(body: redact_payload, secret: "wrong-secret", topic: "customers/redact")
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
