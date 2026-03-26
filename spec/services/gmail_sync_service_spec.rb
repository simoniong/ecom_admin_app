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

  before do
    shopify_lookup = instance_double(ShopifyLookupService)
    allow(ShopifyLookupService).to receive(:new).and_return(shopify_lookup)
    allow(shopify_lookup).to receive(:lookup)
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

    it "extracts real customer from Shopify form email body" do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)

      profile = Google::Apis::GmailV1::Profile.new(history_id: 99)
      allow(gmail).to receive(:user_profile).and_return(profile)

      thread_list = Google::Apis::GmailV1::ListThreadsResponse.new(
        threads: [ Google::Apis::GmailV1::Thread.new(id: "t4") ],
        next_page_token: nil
      )
      allow(gmail).to receive(:list_threads).and_return(thread_list)

      shopify_body = "Name: Jane Customer\nEmail: jane@buyer.com\n\nHi, where is my order #1234?"
      full_thread = build_gmail_thread(
        id: "t4",
        messages: [
          build_gmail_message(
            id: "m4", thread_id: "t4",
            from: "noreply@shopify.com",
            subject: "Contact form submission",
            body: shopify_body
          )
        ]
      )
      allow(gmail).to receive(:get_thread).with("t4").and_return(full_thread)

      service.sync!
      ticket = Ticket.last
      expect(ticket.customer_email).to eq("jane@buyer.com")
      expect(ticket.customer_name).to eq("Jane Customer")
    end

    it "detects customer from To header when sender is account email" do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)

      profile = Google::Apis::GmailV1::Profile.new(history_id: 99)
      allow(gmail).to receive(:user_profile).and_return(profile)

      thread_list = Google::Apis::GmailV1::ListThreadsResponse.new(
        threads: [ Google::Apis::GmailV1::Thread.new(id: "t5") ],
        next_page_token: nil
      )
      allow(gmail).to receive(:list_threads).and_return(thread_list)

      full_thread = build_gmail_thread(
        id: "t5",
        messages: [
          build_gmail_message(id: "m5", thread_id: "t5", from: "shop@gmail.com", to: "Buyer <buyer@test.com>")
        ]
      )
      allow(gmail).to receive(:get_thread).with("t5").and_return(full_thread)

      service.sync!
      expect(Ticket.last.customer_email).to eq("buyer@test.com")
    end
  end

  describe "incremental sync fallback" do
    it "falls back to full sync on 404 history error" do
      email_account.update!(last_history_id: 99999)

      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)

      error = Google::Apis::ClientError.new("not found", status_code: 404)
      allow(gmail).to receive(:list_history).and_raise(error)

      # Full sync fallback
      profile = Google::Apis::GmailV1::Profile.new(history_id: 100000)
      allow(gmail).to receive(:user_profile).and_return(profile)
      allow(gmail).to receive(:list_threads).and_return(
        Google::Apis::GmailV1::ListThreadsResponse.new(threads: nil)
      )

      service.sync!
      expect(email_account.reload.last_history_id).to eq(100000)
    end
  end

  describe "ShopifyLookup error handling" do
    it "continues when ShopifyLookup fails" do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)

      profile = Google::Apis::GmailV1::Profile.new(history_id: 99)
      allow(gmail).to receive(:user_profile).and_return(profile)

      thread_list = Google::Apis::GmailV1::ListThreadsResponse.new(
        threads: [ Google::Apis::GmailV1::Thread.new(id: "t6") ],
        next_page_token: nil
      )
      allow(gmail).to receive(:list_threads).and_return(thread_list)

      full_thread = build_gmail_thread(
        id: "t6",
        messages: [ build_gmail_message(id: "m6", thread_id: "t6", from: "fail@example.com") ]
      )
      allow(gmail).to receive(:get_thread).with("t6").and_return(full_thread)

      shopify = instance_double(ShopifyLookupService)
      allow(ShopifyLookupService).to receive(:new).and_return(shopify)
      allow(shopify).to receive(:lookup).and_raise(RuntimeError, "Shopify down")

      expect { service.sync! }.not_to raise_error
      expect(Ticket.last.customer_email).to eq("fail@example.com")
    end
  end

  describe "multipart message body extraction" do
    it "extracts body from multipart messages" do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)

      profile = Google::Apis::GmailV1::Profile.new(history_id: 99)
      allow(gmail).to receive(:user_profile).and_return(profile)

      thread_list = Google::Apis::GmailV1::ListThreadsResponse.new(
        threads: [ Google::Apis::GmailV1::Thread.new(id: "t7") ],
        next_page_token: nil
      )
      allow(gmail).to receive(:list_threads).and_return(thread_list)

      encoded_body = Base64.urlsafe_encode64("Plain text body")
      full_thread = Google::Apis::GmailV1::Thread.new(
        id: "t7",
        messages: [
          Google::Apis::GmailV1::Message.new(
            id: "m7", thread_id: "t7",
            internal_date: (Time.current.to_f * 1000).to_i,
            payload: Google::Apis::GmailV1::MessagePart.new(
              headers: [
                Google::Apis::GmailV1::MessagePartHeader.new(name: "From", value: "multi@example.com"),
                Google::Apis::GmailV1::MessagePartHeader.new(name: "Subject", value: "Multipart")
              ],
              parts: [
                Google::Apis::GmailV1::MessagePart.new(
                  mime_type: "text/plain",
                  body: Google::Apis::GmailV1::MessagePartBody.new(data: encoded_body)
                ),
                Google::Apis::GmailV1::MessagePart.new(
                  mime_type: "text/html",
                  body: Google::Apis::GmailV1::MessagePartBody.new(data: Base64.urlsafe_encode64("<b>HTML</b>"))
                )
              ]
            )
          )
        ]
      )
      allow(gmail).to receive(:get_thread).with("t7").and_return(full_thread)

      service.sync!
      expect(Message.last.body).to eq("Plain text body")
    end

    it "handles invalid base64 body gracefully" do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)

      profile = Google::Apis::GmailV1::Profile.new(history_id: 99)
      allow(gmail).to receive(:user_profile).and_return(profile)

      thread_list = Google::Apis::GmailV1::ListThreadsResponse.new(
        threads: [ Google::Apis::GmailV1::Thread.new(id: "t8") ],
        next_page_token: nil
      )
      allow(gmail).to receive(:list_threads).and_return(thread_list)

      full_thread = Google::Apis::GmailV1::Thread.new(
        id: "t8",
        messages: [
          Google::Apis::GmailV1::Message.new(
            id: "m8", thread_id: "t8",
            internal_date: (Time.current.to_f * 1000).to_i,
            payload: Google::Apis::GmailV1::MessagePart.new(
              headers: [
                Google::Apis::GmailV1::MessagePartHeader.new(name: "From", value: "bad@example.com"),
                Google::Apis::GmailV1::MessagePartHeader.new(name: "Subject", value: "Bad encoding")
              ],
              body: Google::Apis::GmailV1::MessagePartBody.new(data: "not-valid-base64!!!")
            )
          )
        ]
      )
      allow(gmail).to receive(:get_thread).with("t8").and_return(full_thread)

      service.sync!
      expect(Message.last.body).to eq("not-valid-base64!!!")
    end
  end
end
