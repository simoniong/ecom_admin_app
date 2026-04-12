require "rails_helper"

RSpec.describe NotifyAgentJob, type: :job do
  let(:ticket) { create(:ticket, email_account: create(:email_account)) }

  describe "#perform" do
    it "calls DiscordWebhookService.notify_new_ticket for new_ticket type" do
      expect(DiscordWebhookService).to receive(:notify_new_ticket).with(ticket)

      described_class.new.perform(ticket.id, "new_ticket")
    end

    it "calls DiscordWebhookService.notify_revise_draft for revise_draft type" do
      expect(DiscordWebhookService).to receive(:notify_revise_draft).with(ticket, "make it polite")

      described_class.new.perform(ticket.id, "revise_draft", "make it polite")
    end

    it "logs warning when ticket is not found" do
      expect(Rails.logger).to receive(:warn).with(/Ticket not found/)

      described_class.new.perform("00000000-0000-0000-0000-000000000000", "new_ticket")
    end

    it "logs error when Discord delivery fails" do
      allow(DiscordWebhookService).to receive(:notify_new_ticket)
        .and_raise(DiscordWebhookService::DeliveryError, "Discord webhook failed: 500")

      expect(Rails.logger).to receive(:error).with(/Discord webhook failed/)

      described_class.new.perform(ticket.id, "new_ticket")
    end
  end
end
