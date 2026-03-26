require "rails_helper"

RSpec.describe Ticket, type: :model do
  let(:email_account) { create(:email_account) }
  let(:ticket) { create(:ticket, email_account: email_account) }

  it "is valid with valid attributes" do
    expect(ticket).to be_valid
  end

  it "generates a UUID id" do
    expect(ticket.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to email_account" do
    expect(ticket.email_account).to eq(email_account)
  end

  it "requires gmail_thread_id" do
    ticket.gmail_thread_id = ""
    expect(ticket).not_to be_valid
  end

  it "enforces gmail_thread_id uniqueness per email_account" do
    duplicate = build(:ticket, email_account: email_account, gmail_thread_id: ticket.gmail_thread_id)
    expect(duplicate).not_to be_valid
  end

  it "allows same gmail_thread_id for different email_accounts" do
    other_account = create(:email_account)
    other_ticket = build(:ticket, email_account: other_account, gmail_thread_id: ticket.gmail_thread_id)
    expect(other_ticket).to be_valid
  end

  it "requires customer_email" do
    ticket.customer_email = ""
    expect(ticket).not_to be_valid
  end

  it "defaults status to new_ticket" do
    t = Ticket.new
    expect(t.status).to eq("new_ticket")
  end

  it "supports all status enum values" do
    expect(Ticket.statuses.keys).to match_array(%w[new_ticket draft draft_confirmed closed])
  end

  it "destroys messages on destroy" do
    create(:message, ticket: ticket)
    expect { ticket.destroy }.to change(Message, :count).by(-1)
  end

  describe "scopes" do
    it ".by_recency orders by last_message_at desc" do
      old = create(:ticket, email_account: email_account, last_message_at: 2.days.ago)
      recent = create(:ticket, email_account: email_account, last_message_at: 1.hour.ago)
      expect(Ticket.by_recency).to eq([ recent, old ])
    end

    it ".for_user returns only tickets for the given user" do
      user = email_account.user
      other_account = create(:email_account)
      other_ticket = create(:ticket, email_account: other_account)

      expect(Ticket.for_user(user)).to include(ticket)
      expect(Ticket.for_user(user)).not_to include(other_ticket)
    end
  end
end
