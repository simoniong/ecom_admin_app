require "rails_helper"

RSpec.describe SendScheduledEmailJob, type: :job do
  let(:email_account) { create(:email_account, email: "shop@gmail.com", token_expires_at: 1.hour.from_now) }
  let(:ticket) do
    create(:ticket, :draft_confirmed, email_account: email_account,
           gmail_thread_id: "thread-abc", customer_email: "buyer@example.com",
           scheduled_send_at: Time.current, scheduled_job_id: nil)
  end

  before do
    create(:message, ticket: ticket, from: "buyer@example.com", gmail_message_id: "msg-orig")

    gmail = instance_double(GmailService)
    allow(GmailService).to receive(:new).and_return(gmail)
    sent = Google::Apis::GmailV1::Message.new(id: "sent-msg-id", thread_id: "thread-abc")
    allow(gmail).to receive(:send_message).and_return(sent)
  end

  it "sends email and closes ticket" do
    job = described_class.new(ticket.id)
    ticket.update!(scheduled_job_id: job.job_id)

    job.perform_now
    ticket.reload

    expect(ticket).to be_closed
    expect(ticket.scheduled_send_at).to be_nil
    expect(ticket.scheduled_job_id).to be_nil
    expect(ticket.messages.count).to eq(2)
    expect(ticket.messages.last.gmail_message_id).to eq("sent-msg-id")
  end

  it "skips if ticket is no longer draft_confirmed" do
    ticket.update!(status: :draft, draft_reply: "draft")

    expect(GmailService).not_to receive(:new)
    described_class.perform_now(ticket.id)
  end

  it "skips if job_id does not match scheduled_job_id (stale job)" do
    ticket.update!(scheduled_job_id: "current-active-job")

    expect(GmailService).not_to receive(:new)
    described_class.perform_now(ticket.id)
  end

  it "sends when scheduled_job_id is nil (backwards compat)" do
    ticket.update!(scheduled_job_id: nil)
    described_class.perform_now(ticket.id)
    expect(ticket.reload).to be_closed
  end

  it "sends with legacy expected_job_id param (backwards compat)" do
    ticket.update!(scheduled_job_id: "legacy-uuid")
    described_class.perform_now(ticket.id, expected_job_id: "legacy-uuid")
    expect(ticket.reload).to be_closed
  end

  it "skips legacy job when scheduled_job_id has been updated" do
    ticket.update!(scheduled_job_id: "new-uuid")

    expect(GmailService).not_to receive(:new)
    described_class.perform_now(ticket.id, expected_job_id: "old-uuid")
  end

  it "raises on send failure for retry" do
    job = described_class.new(ticket.id)
    ticket.update!(scheduled_job_id: job.job_id)

    gmail = instance_double(GmailService)
    allow(GmailService).to receive(:new).and_return(gmail)
    allow(gmail).to receive(:send_message).and_raise(RuntimeError, "Gmail API error")

    expect { job.perform_now }.to raise_error(RuntimeError, /Gmail API error/)
  end

  it "clears the in-flight marker after a successful send" do
    job = described_class.new(ticket.id)
    ticket.update!(scheduled_job_id: job.job_id)

    job.perform_now
    ticket.reload

    expect(ticket.sending_started_at).to be_nil
    expect(ticket).to be_closed
  end

  it "does not resend when the ticket is already claimed (mid-send crash recovery)" do
    job = described_class.new(ticket.id)
    ticket.update!(scheduled_job_id: job.job_id, sending_started_at: 1.minute.ago)

    expect(GmailService).not_to receive(:new)

    expect { job.perform_now }.not_to change { ticket.reload.messages.count }
    ticket.reload
    expect(ticket).to be_draft_confirmed
  end

  it "clears the marker on a definitely-unsent error (retryable)" do
    job = described_class.new(ticket.id)
    ticket.update!(scheduled_job_id: job.job_id)

    gmail = instance_double(GmailService)
    allow(GmailService).to receive(:new).and_return(gmail)
    allow(gmail).to receive(:send_message).and_raise(Google::Apis::ClientError.new("bad request"))

    expect { job.perform_now }.to raise_error(Google::Apis::ClientError, /bad request/)

    ticket.reload
    expect(ticket.sending_started_at).to be_nil
    expect(ticket).to be_draft_confirmed
    expect(ticket.messages.count).to eq(1)
  end

  it "clears the marker on a token-refresh failure (retryable)" do
    job = described_class.new(ticket.id)
    ticket.update!(scheduled_job_id: job.job_id)

    gmail = instance_double(GmailService)
    allow(GmailService).to receive(:new).and_return(gmail)
    allow(gmail).to receive(:send_message).and_raise(GmailService::TokenRefreshError.new("Token refresh failed: boom"))

    expect { job.perform_now }.to raise_error(GmailService::TokenRefreshError, /Token refresh failed: boom/)

    ticket.reload
    expect(ticket.sending_started_at).to be_nil
    expect(ticket).to be_draft_confirmed
    expect(ticket.messages.count).to eq(1)
  end

  it "leaves the marker set on an ambiguous error (needs human review)" do
    job = described_class.new(ticket.id)
    ticket.update!(scheduled_job_id: job.job_id)

    gmail = instance_double(GmailService)
    allow(GmailService).to receive(:new).and_return(gmail)
    allow(gmail).to receive(:send_message).and_raise(Google::Apis::ServerError.new("upstream 503"))

    expect { job.perform_now }.to raise_error(Google::Apis::ServerError, /upstream 503/)

    ticket.reload
    expect(ticket.sending_started_at).to be_present
    expect(ticket).to be_draft_confirmed
    expect(ticket.messages.count).to eq(1)
  end

  it "leaves the marker set when a post-send DB write fails" do
    # Drive a real (unmocked) DB failure after a successful send: the stubbed
    # Gmail response returns gmail_message_id "sent-msg-id", so pre-creating a
    # message with that same id trips the model's real uniqueness validation
    # on `ticket.messages.create!` — no domain object is mocked.
    other_ticket = create(:ticket, :draft_confirmed, email_account: email_account,
                          gmail_thread_id: "thread-xyz", customer_email: "other@example.com")
    create(:message, ticket: other_ticket, from: "buyer@example.com", gmail_message_id: "sent-msg-id")

    job = described_class.new(ticket.id)
    ticket.update!(scheduled_job_id: job.job_id)

    expect { job.perform_now }.to raise_error(ActiveRecord::RecordInvalid)

    ticket.reload
    expect(ticket.sending_started_at).to be_present
    expect(ticket).to be_draft_confirmed
    expect(ticket.messages.count).to eq(1)
  end

  context "agent-initiated thread with no gmail_thread_id" do
    let(:agent_ticket) do
      create(:ticket, :draft_confirmed, email_account: email_account,
             gmail_thread_id: nil, initiated_by: :agent, subject: "Your order shipped",
             customer_email: "buyer@example.com",
             scheduled_send_at: Time.current, scheduled_job_id: nil)
    end

    before do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)
      sent = Google::Apis::GmailV1::Message.new(id: "new-sent-id", thread_id: "brand-new-thread")
      allow(gmail).to receive(:send_message).and_return(sent)
      @gmail = gmail
    end

    it "sends without a thread_id and with the raw subject" do
      described_class.perform_now(agent_ticket.id)
      expect(@gmail).to have_received(:send_message)
        .with(hash_including(thread_id: nil, subject: "Your order shipped"))
    end

    it "backfills gmail_thread_id and closes the ticket" do
      described_class.perform_now(agent_ticket.id)
      agent_ticket.reload
      expect(agent_ticket.gmail_thread_id).to eq("brand-new-thread")
      expect(agent_ticket).to be_closed
    end
  end

  context "Trustpilot BCC" do
    let(:store) { create(:shopify_store, trustpilot_bcc_email: "shop.com+abc@invite.trustpilot.com") }
    let(:email_account) { create(:email_account, email: "shop@gmail.com", token_expires_at: 1.hour.from_now, shopify_store: store) }

    def run_confirmed_ticket(bcc_flag, snapshot)
      t = create(:ticket, :draft_confirmed, email_account: email_account,
                 gmail_thread_id: "thread-t", customer_email: "buyer@example.com",
                 scheduled_send_at: Time.current, scheduled_job_id: nil,
                 bcc_trustpilot: bcc_flag, trustpilot_bcc_email: snapshot)
      job = described_class.new(t.id)
      t.update!(scheduled_job_id: job.job_id)
      job.perform_now
      t.reload
    end

    it "passes the snapshot address as BCC and records it when present" do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)
      sent = Google::Apis::GmailV1::Message.new(id: "sent-1", thread_id: "thread-t")
      expect(gmail).to receive(:send_message)
        .with(hash_including(bcc: "shop.com+abc@invite.trustpilot.com")).and_return(sent)

      t = run_confirmed_ticket(true, "shop.com+abc@invite.trustpilot.com")
      expect(t.messages.last.bcc).to eq("shop.com+abc@invite.trustpilot.com")
    end

    it "sends no BCC when the snapshot is nil" do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)
      sent = Google::Apis::GmailV1::Message.new(id: "sent-2", thread_id: "thread-t")
      expect(gmail).to receive(:send_message).with(hash_including(bcc: nil)).and_return(sent)

      t = run_confirmed_ticket(false, nil)
      expect(t.messages.last.bcc).to be_nil
    end

    it "sends no BCC when the flag is set but the snapshot is nil" do
      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)
      sent = Google::Apis::GmailV1::Message.new(id: "sent-3", thread_id: "thread-t")
      expect(gmail).to receive(:send_message).with(hash_including(bcc: nil)).and_return(sent)

      t = run_confirmed_ticket(true, nil)
      expect(t.messages.last.bcc).to be_nil
    end

    it "ignores the live store association and uses only the snapshot (re-linking immunity)" do
      store.update!(trustpilot_bcc_email: "different-store.com+z@invite.trustpilot.com")

      gmail = instance_double(GmailService)
      allow(GmailService).to receive(:new).and_return(gmail)
      sent = Google::Apis::GmailV1::Message.new(id: "sent-4", thread_id: "thread-t")
      expect(gmail).to receive(:send_message)
        .with(hash_including(bcc: "snap.com+x@invite.trustpilot.com")).and_return(sent)

      t = run_confirmed_ticket(true, "snap.com+x@invite.trustpilot.com")
      expect(t.messages.last.bcc).to eq("snap.com+x@invite.trustpilot.com")
    end
  end
end
