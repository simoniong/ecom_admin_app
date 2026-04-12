require "rails_helper"

RSpec.describe DiscordWebhookService do
  let(:ticket) { create(:ticket, email_account: create(:email_account)) }
  let(:webhook_url) { "https://discord.com/api/webhooks/123/abc" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DISCORD_WEBHOOK_URL").and_return(webhook_url)
  end

  describe ".notify_new_ticket" do
    it "sends a new ticket notification to Discord" do
      stub = stub_request(:post, webhook_url)
        .with(
          headers: { "Content-Type" => "application/json" },
          body: { content: "新 ticket，請生成 draft。Ticket ID: #{ticket.id}" }.to_json
        )
        .to_return(status: 204)

      DiscordWebhookService.notify_new_ticket(ticket)

      expect(stub).to have_been_requested
    end
  end

  describe ".notify_revise_draft" do
    it "sends a revise draft notification to Discord" do
      stub = stub_request(:post, webhook_url)
        .with(
          headers: { "Content-Type" => "application/json" },
          body: { content: "Ticket ID: #{ticket.id}, 語氣更溫和一點" }.to_json
        )
        .to_return(status: 204)

      DiscordWebhookService.notify_revise_draft(ticket, "語氣更溫和一點")

      expect(stub).to have_been_requested
    end
  end

  context "when webhook URL is not configured" do
    before do
      allow(ENV).to receive(:[]).with("DISCORD_WEBHOOK_URL").and_return(nil)
    end

    it "does not make any HTTP request" do
      DiscordWebhookService.notify_new_ticket(ticket)

      expect(WebMock).not_to have_requested(:post, /discord/)
    end
  end

  context "when Discord returns an error" do
    it "raises DeliveryError" do
      stub_request(:post, webhook_url).to_return(status: 500, body: "Internal Server Error")

      expect {
        DiscordWebhookService.notify_new_ticket(ticket)
      }.to raise_error(DiscordWebhookService::DeliveryError, /500/)
    end
  end
end
