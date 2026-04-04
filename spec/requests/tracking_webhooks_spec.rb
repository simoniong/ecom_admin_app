require "rails_helper"

RSpec.describe "Tracking Webhooks", type: :request do
  describe "POST /tracking/webhooks" do
    it "enqueues ProcessTrackingWebhookJob and returns ok" do
      expect {
        post "/tracking/webhooks", params: { number: "TRACK123" }, as: :json
      }.to have_enqueued_job(ProcessTrackingWebhookJob)

      expect(response).to have_http_status(:ok)
    end

    context "with webhook token configured" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("SEVENTEEN_TRACK_WEBHOOK_TOKEN").and_return("secret-token")
      end

      it "rejects requests without valid token" do
        post "/tracking/webhooks", params: { number: "TRACK123" }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it "accepts requests with valid token param" do
        post "/tracking/webhooks", params: { number: "TRACK123", token: "secret-token" }, as: :json
        expect(response).to have_http_status(:ok)
      end

      it "accepts requests with valid token header" do
        post "/tracking/webhooks",
             params: { number: "TRACK123" },
             headers: { "X-17Track-Token" => "secret-token" },
             as: :json
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
