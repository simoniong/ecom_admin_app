require "rails_helper"

RSpec.describe GmailSyncService do
  let(:email_account) { create(:email_account, email: "shop@gmail.com", token_expires_at: 1.hour.from_now) }
  let(:service) { described_class.new(email_account) }

  def build_gmail_message(id:, thread_id:, from:, to: "shop@gmail.com", subject: "Test", body: "Hello", internal_date: nil)
    internal_date ||= (Time.current.to_f * 1000).to_i
    encoded_body = Base64.urlsafe_encode64(body)

    Google::Apis::GmailV1::Message.new(
      id: id,
      thread_id: thread_id,
      internal_date: internal_date,
      payload: Google::Apis::GmailV1::MessagePart.new(
        headers: [
          Google::Apis::GmailV1::MessagePartHeader.new(name: "From", value: from),
          Google::Apis::GmailV1::MessagePartHeader.new(name: "To", value: to),
          Google::Apis::GmailV1::MessagePartHeader.new(name: "Subject", value: subject)
        ],
        body: Google::Apis::GmailV1::MessagePartBody.new(data: encoded_body)
      )
    )
  end

  def build_gmail_thread(id:, messages:)
    Google::Apis::GmailV1::Thread.new(id: id, messages: messages)
  end

  describe "#sync! (full sync)" do
    before do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)

      profile = Google::Apis::GmailV1::Profile.new(history_id: 12345)
      allow(gmail).to receive(:user_profile).and_return(profile)

      thread_list = Google::Apis::GmailV1::ListThreadsResponse.new(
        threads: [ Google::Apis::GmailV1::Thread.new(id: "t1") ],
        next_page_token: nil
      )
      allow(gmail).to receive(:list_threads).and_return(thread_list)

      full_thread = build_gmail_thread(
        id: "t1",
        messages: [
          build_gmail_message(id: "m1", thread_id: "t1", from: "customer@example.com", subject: "Help me")
        ]
      )
      allow(gmail).to receive(:get_thread).with("t1").and_return(full_thread)

      # For idempotent test — second sync uses incremental mode
      history_response = Google::Apis::GmailV1::ListHistoryResponse.new(
        history: nil,
        history_id: 12345
      )
      allow(gmail).to receive(:list_history).and_return(history_response)
    end

    it "creates a ticket and message" do
      expect { service.sync! }.to change(Ticket, :count).by(1).and change(Message, :count).by(1)

      ticket = Ticket.last
      expect(ticket.gmail_thread_id).to eq("t1")
      expect(ticket.customer_email).to eq("customer@example.com")
      expect(ticket.subject).to eq("Help me")
      expect(ticket.status).to eq("new_ticket")
    end

    it "updates last_synced_at and last_history_id" do
      service.sync!
      email_account.reload
      expect(email_account.last_synced_at).to be_present
      expect(email_account.last_history_id).to eq(12345)
    end

    it "is idempotent — does not create duplicates" do
      service.sync!
      expect { service.sync! }.not_to change(Ticket, :count)
    end
  end

  describe "#sync! (incremental sync)" do
    before do
      email_account.update!(last_history_id: 10000)

      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)

      message_added = Google::Apis::GmailV1::HistoryMessageAdded.new(
        message: Google::Apis::GmailV1::Message.new(id: "m2", thread_id: "t2")
      )
      history = Google::Apis::GmailV1::History.new(messages_added: [ message_added ])
      history_response = Google::Apis::GmailV1::ListHistoryResponse.new(
        history: [ history ],
        history_id: 10100
      )
      allow(gmail).to receive(:list_history).and_return(history_response)

      full_thread = build_gmail_thread(
        id: "t2",
        messages: [
          build_gmail_message(id: "m2", thread_id: "t2", from: "buyer@example.com", subject: "Where is my order?")
        ]
      )
      allow(gmail).to receive(:get_thread).with("t2").and_return(full_thread)
    end

    it "creates ticket from history" do
      expect { service.sync! }.to change(Ticket, :count).by(1)
      expect(Ticket.last.subject).to eq("Where is my order?")
    end

    it "updates last_history_id" do
      service.sync!
      expect(email_account.reload.last_history_id).to eq(10100)
    end
  end

  describe "customer detection" do
    it "sets status to closed when thread has our reply" do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)

      profile = Google::Apis::GmailV1::Profile.new(history_id: 99)
      allow(gmail).to receive(:user_profile).and_return(profile)

      thread_list = Google::Apis::GmailV1::ListThreadsResponse.new(
        threads: [ Google::Apis::GmailV1::Thread.new(id: "t3") ],
        next_page_token: nil
      )
      allow(gmail).to receive(:list_threads).and_return(thread_list)

      full_thread = build_gmail_thread(
        id: "t3",
        messages: [
          build_gmail_message(id: "m3a", thread_id: "t3", from: "customer@example.com"),
          build_gmail_message(id: "m3b", thread_id: "t3", from: "shop@gmail.com", to: "customer@example.com")
        ]
      )
      allow(gmail).to receive(:get_thread).with("t3").and_return(full_thread)

      service.sync!
      expect(Ticket.last.status).to eq("closed")
    end
  end
end
