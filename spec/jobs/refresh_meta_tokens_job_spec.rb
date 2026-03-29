require "rails_helper"

RSpec.describe RefreshMetaTokensJob, type: :job do
  it "refreshes tokens expiring within 7 days" do
    account = create(:ad_account, token_expires_at: 3.days.from_now)

    service = instance_double(MetaAdsService)
    allow(MetaAdsService).to receive(:new).with(account).and_return(service)
    allow(service).to receive(:refresh_token_if_needed!)

    described_class.perform_now

    expect(service).to have_received(:refresh_token_if_needed!)
  end

  it "skips accounts with tokens not expiring soon" do
    create(:ad_account, token_expires_at: 30.days.from_now)

    expect(MetaAdsService).not_to receive(:new)
    described_class.perform_now
  end

  it "handles errors gracefully" do
    create(:ad_account, token_expires_at: 3.days.from_now)

    service = instance_double(MetaAdsService)
    allow(MetaAdsService).to receive(:new).and_return(service)
    allow(service).to receive(:refresh_token_if_needed!).and_raise(RuntimeError, "Token refresh failed")

    expect { described_class.perform_now }.not_to raise_error
  end
end
