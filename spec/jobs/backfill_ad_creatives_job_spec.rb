require "rails_helper"

RSpec.describe BackfillAdCreativesJob, type: :job do
  let(:ad_account) { create(:ad_account) }

  it "releases the throttle slot after a successful run" do
    ad_account.update_columns(creative_backfill_attempts: 3, creative_backfill_next_attempt_at: 5.hours.from_now)
    service = instance_double(AdCreativeBackfillService, call: true)
    allow(AdCreativeBackfillService).to receive(:new).and_return(service)

    described_class.perform_now(ad_account_id: ad_account.id)

    expect(ad_account.reload.creative_backfill_attempts).to eq(0)
    expect(ad_account.creative_backfill_next_attempt_at).to be_nil
  end

  it "leaves the backoff in place after a failed run" do
    ad_account.update_columns(creative_backfill_attempts: 3, creative_backfill_next_attempt_at: 5.hours.from_now)
    service = instance_double(AdCreativeBackfillService, call: false)
    allow(AdCreativeBackfillService).to receive(:new).and_return(service)

    described_class.perform_now(ad_account_id: ad_account.id)

    expect(ad_account.reload.creative_backfill_attempts).to eq(3)
  end

  it "skips an account whose token has expired" do
    ad_account.update_column(:token_expires_at, 1.day.ago)
    expect(AdCreativeBackfillService).not_to receive(:new)

    described_class.perform_now(ad_account_id: ad_account.id)
  end

  it "does not raise when the account no longer exists" do
    expect { described_class.perform_now(ad_account_id: SecureRandom.uuid) }.not_to raise_error
  end

  it "rescues an unexpected error and logs it" do
    allow(AdCreativeBackfillService).to receive(:new).and_raise(StandardError, "kaboom")
    expect(Rails.logger).to receive(:error).with(/kaboom/)

    expect { described_class.perform_now(ad_account_id: ad_account.id) }.not_to raise_error
  end
end
