require "rails_helper"

RSpec.describe SyncGmailThreadsJob, type: :job do
  it "calls GmailSyncService for each email account" do
    account1 = create(:email_account)
    account2 = create(:email_account)

    sync1 = instance_double(GmailSyncService)
    sync2 = instance_double(GmailSyncService)

    allow(GmailSyncService).to receive(:new).with(account1).and_return(sync1)
    allow(GmailSyncService).to receive(:new).with(account2).and_return(sync2)
    allow(sync1).to receive(:sync!)
    allow(sync2).to receive(:sync!)

    described_class.perform_now

    expect(sync1).to have_received(:sync!)
    expect(sync2).to have_received(:sync!)
  end

  it "continues when one account fails" do
    account1 = create(:email_account)
    account2 = create(:email_account)

    sync1 = instance_double(GmailSyncService)
    sync2 = instance_double(GmailSyncService)

    allow(GmailSyncService).to receive(:new).with(account1).and_return(sync1)
    allow(GmailSyncService).to receive(:new).with(account2).and_return(sync2)
    allow(sync1).to receive(:sync!).and_raise(RuntimeError, "API error")
    allow(sync2).to receive(:sync!)

    expect { described_class.perform_now }.not_to raise_error

    expect(sync2).to have_received(:sync!)
  end
end
