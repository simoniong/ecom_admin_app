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

  it "raises on send failure for retry" do
    job = described_class.new(ticket.id)
    ticket.update!(scheduled_job_id: job.job_id)

    gmail = instance_double(GmailService)
    allow(GmailService).to receive(:new).and_return(gmail)
    allow(gmail).to receive(:send_message).and_raise(RuntimeError, "Gmail API error")

    expect { job.perform_now }.to raise_error(RuntimeError, /Gmail API error/)
  end
end
