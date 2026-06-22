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
end
