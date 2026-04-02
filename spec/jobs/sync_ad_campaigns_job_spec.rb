require "rails_helper"

RSpec.describe SyncAdCampaignsJob, type: :job do
  it "syncs campaigns and insights for each meta ad account" do
    account = create(:ad_account, token_expires_at: 30.days.from_now)

    service = instance_double(MetaAdsService)
    allow(MetaAdsService).to receive(:new).with(account).and_return(service)
    allow(service).to receive(:refresh_token_if_needed!)
    allow(service).to receive(:sync_campaigns)
    allow(service).to receive(:sync_campaign_insights)

    described_class.perform_now

    expect(service).to have_received(:sync_campaigns)
    expect(service).to have_received(:sync_campaign_insights).with(2.days.ago.to_date, Date.current)
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
    allow(service).to receive(:sync_campaigns).and_raise(RuntimeError, "API error")

    expect { described_class.perform_now }.not_to raise_error
  end

  it "does nothing when no ad accounts exist" do
    expect(MetaAdsService).not_to receive(:new)
    described_class.perform_now
  end

  it "accepts custom days parameter" do
    account = create(:ad_account, token_expires_at: 30.days.from_now)

    service = instance_double(MetaAdsService)
    allow(MetaAdsService).to receive(:new).with(account).and_return(service)
    allow(service).to receive(:refresh_token_if_needed!)
    allow(service).to receive(:sync_campaigns)
    allow(service).to receive(:sync_campaign_insights)

    described_class.perform_now(days: 7)

    expect(service).to have_received(:sync_campaign_insights).with(7.days.ago.to_date, Date.current)
  end
end
