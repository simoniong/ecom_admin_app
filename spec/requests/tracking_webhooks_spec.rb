require "rails_helper"

RSpec.describe "Tracking Webhooks", type: :request do
  describe "POST /tracking/webhooks" do
    context "without webhook token configured" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("SEVENTEEN_TRACK_WEBHOOK_TOKEN").and_return(nil)
        allow(Rails.application.credentials).to receive(:dig).with(:seventeen_track, :webhook_token).and_return(nil)
      end

      it "rejects requests when token is not configured" do
        post "/tracking/webhooks", params: { number: "TRACK123" }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with webhook token configured" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("SEVENTEEN_TRACK_WEBHOOK_TOKEN").and_return("secret-token")
      end

      it "enqueues ProcessTrackingWebhookJob and returns ok with valid token" do
        expect {
          post "/tracking/webhooks", params: { number: "TRACK123", token: "secret-token" }, as: :json
        }.to have_enqueued_job(ProcessTrackingWebhookJob)

        expect(response).to have_http_status(:ok)
      end

      it "rejects requests without valid token" do
        post "/tracking/webhooks", params: { number: "TRACK123" }, as: :json
        expect(response).to have_http_status(:unauthorized)
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
