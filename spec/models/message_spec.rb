require "rails_helper"

RSpec.describe Message, type: :model do
  let(:message) { create(:message) }

  it "is valid with valid attributes" do
    expect(message).to be_valid
  end

  it "generates a UUID id" do
    expect(message.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to ticket" do
    expect(message.ticket).to be_a(Ticket)
  end

  it "requires gmail_message_id" do
    message.gmail_message_id = ""
    expect(message).not_to be_valid
  end

  it "enforces gmail_message_id uniqueness" do
    duplicate = build(:message, gmail_message_id: message.gmail_message_id)
    expect(duplicate).not_to be_valid
  end

  it "requires from" do
    message.from = ""
    expect(message).not_to be_valid
  end

  describe ".chronological" do
    it "orders by sent_at asc" do
      ticket = create(:ticket)
      old_msg = create(:message, ticket: ticket, sent_at: 2.hours.ago)
      new_msg = create(:message, ticket: ticket, sent_at: 1.hour.ago)
      expect(ticket.messages.chronological).to eq([ old_msg, new_msg ])
    end
  end

  describe "#sent_at_in_zone" do
    it "converts to specified timezone" do
      msg = build(:message, sent_at: Time.utc(2026, 3, 26, 10, 0, 0))
      result = msg.sent_at_in_zone("Asia/Shanghai")
      expect(result.hour).to eq(18)
    end

    it "defaults to Asia/Shanghai" do
      msg = build(:message, sent_at: Time.utc(2026, 3, 26, 10, 0, 0))
      result = msg.sent_at_in_zone
      expect(result.zone).to include("CST").or include("+08")
    end

    it "returns nil when sent_at is nil" do
      msg = build(:message, sent_at: nil)
      expect(msg.sent_at_in_zone).to be_nil
    end
  end
end
