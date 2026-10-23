require "rails_helper"

RSpec.describe SyncAdMetricsJob, type: :job do
  it "syncs metrics for each meta ad account" do
    account = create(:ad_account, token_expires_at: 30.days.from_now)

    service = instance_double(MetaAdsService)
    allow(MetaAdsService).to receive(:new).with(account).and_return(service)
    allow(service).to receive(:refresh_token_if_needed!)
    allow(service).to receive(:sync_date_range)

    described_class.perform_now

    expect(service).to have_received(:sync_date_range).with(2.days.ago.to_date, Date.current)
  end

  it "skips expired tokens" do
    create(:ad_account, token_expires_at: 1.day.ago)

    expect(MetaAdsService).not_to receive(:new)
    described_class.perform_now
  end

  it "handles errors gracefully" do
    create(:ad_account, token_expires_at: 30.days.from_now)

    service = instance_double(MetaAdsService)
    allow(MetaAdsService).to receive(:new).and_return(service)
    allow(service).to receive(:refresh_token_if_needed!)
    allow(service).to receive(:sync_date_range).and_raise(RuntimeError, "API error")

    expect { described_class.perform_now }.not_to raise_error
  end

  it "does nothing when no ad accounts exist" do
    expect(MetaAdsService).not_to receive(:new)
    described_class.perform_now
  end

  it "records a succeeded auto run per account" do
    account = create(:ad_account, token_expires_at: 30.days.from_now)
    service = instance_double(MetaAdsService, refresh_token_if_needed!: nil, sync_date_range: nil)
    allow(MetaAdsService).to receive(:new).and_return(service)

    described_class.perform_now

    run = SyncRun.where(source: "meta_ads", target: account).last
    expect(run.status).to eq("succeeded")
    expect(run.trigger).to eq("auto")
  end

  it "records an expired-token account as failed with the reconnect message" do
    account = create(:ad_account, token_expires_at: 1.day.ago)

    described_class.perform_now

    run = SyncRun.where(source: "meta_ads", target: account).last
    expect(run.status).to eq("failed")
    expect(run.error_message).to eq("Token expired — reconnect this ad account")
  end

  it "limits to ad_account_ids" do
    account_a = create(:ad_account, token_expires_at: 30.days.from_now)
    account_b = create(:ad_account, token_expires_at: 30.days.from_now)
    service = instance_double(MetaAdsService, refresh_token_if_needed!: nil, sync_date_range: nil)
    allow(MetaAdsService).to receive(:new).and_return(service)

    described_class.perform_now(ad_account_ids: [ account_a.id ])

    expect(SyncRun.where(source: "meta_ads", target: account_a)).to be_present
    expect(SyncRun.where(source: "meta_ads", target: account_b)).to be_empty
  end
end
