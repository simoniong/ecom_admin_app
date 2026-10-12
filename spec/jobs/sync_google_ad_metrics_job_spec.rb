require "rails_helper"

RSpec.describe SyncGoogleAdMetricsJob, type: :job do
  let!(:google) { create(:ad_account, :google, timezone: "America/Los_Angeles") }

  def stub_service
    service = instance_double(GoogleAdsService, sync_date_range: nil, sync_campaigns: nil)
    allow(GoogleAdsService).to receive(:new).and_return(service)
    service
  end

  it "re-syncs the last week of every Google account, in the account's timezone" do
    create(:ad_account) # Meta: not this job's business
    service = stub_service

    described_class.perform_now

    today = google.today_in_zone
    expect(GoogleAdsService).to have_received(:new).once.with(google)
    expect(service).to have_received(:sync_date_range).with(today - 7, today)
    expect(service).to have_received(:sync_campaigns).with(today - 7, today)
  end

  it "backfills a single account over the requested number of days" do
    other = create(:ad_account, :google)
    service = stub_service

    described_class.perform_now(ad_account_id: google.id, days: 730)

    expect(GoogleAdsService).to have_received(:new).once.with(google)
    expect(GoogleAdsService).not_to have_received(:new).with(other)
    expect(service).to have_received(:sync_date_range).with(google.today_in_zone - 730, google.today_in_zone)
  end

  it "limits the run to one company's accounts" do
    other_company = create(:ad_account, :google)
    stub_service

    described_class.perform_now(company_id: google.company_id)

    expect(GoogleAdsService).to have_received(:new).once.with(google)
    expect(GoogleAdsService).not_to have_received(:new).with(other_company)
  end

  it "skips accounts whose token has been rejected" do
    google.update!(token_expires_at: 1.minute.ago)
    stub_service

    described_class.perform_now

    expect(GoogleAdsService).not_to have_received(:new)
  end

  it "keeps going when one account fails" do
    second = create(:ad_account, :google)
    service = instance_double(GoogleAdsService)
    allow(GoogleAdsService).to receive(:new).and_return(service)
    allow(service).to receive(:sync_date_range).and_raise(GoogleAdsApi::Error, "boom")

    expect { described_class.perform_now }.not_to raise_error
    expect(GoogleAdsService).to have_received(:new).with(second)
  end
end
