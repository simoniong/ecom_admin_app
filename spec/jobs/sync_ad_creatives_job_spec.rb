require "rails_helper"

RSpec.describe SyncAdCreativesJob do
  let(:today) { Date.new(2026, 7, 25) }
  let!(:ad_account) { create(:ad_account, timezone: "UTC") }

  before do
    allow_any_instance_of(AdAccount).to receive(:today_in_zone).and_return(today)
  end

  def make_eligible(through: today)
    ad_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: through)
  end

  describe "eligibility" do
    it "syncs an account whose coverage reaches today" do
      make_eligible(through: today)
      service = instance_double(AdCreativeBackfillService)
      allow(AdCreativeBackfillService).to receive(:new).and_return(service)
      expect(service).to receive(:sync_range).and_return(true)

      described_class.perform_now
    end

    it "syncs an account whose coverage reaches yesterday" do
      make_eligible(through: today - 1)
      service = instance_double(AdCreativeBackfillService)
      allow(AdCreativeBackfillService).to receive(:new).and_return(service)
      expect(service).to receive(:sync_range).and_return(true)

      described_class.perform_now
    end
  end

  describe "self-healing" do
    it "enqueues a backfill for an account that has never synced" do
      expect {
        described_class.perform_now
      }.to have_enqueued_job(BackfillAdCreativesJob).with(ad_account_id: ad_account.id, days: 90)
    end

    it "enqueues a backfill when coverage has fallen more than a day behind" do
      make_eligible(through: today - 5)

      expect {
        described_class.perform_now
      }.to have_enqueued_job(BackfillAdCreativesJob)
    end

    it "does not enqueue a backfill for an eligible account" do
      make_eligible(through: today)
      allow_any_instance_of(AdCreativeBackfillService).to receive(:sync_range).and_return(true)

      expect { described_class.perform_now }.not_to have_enqueued_job(BackfillAdCreativesJob)
    end

    it "warns when an account is ineligible" do
      expect(Rails.logger).to receive(:warn).with(/#{ad_account.account_id}/)

      described_class.perform_now
    end
  end

  describe "throttling" do
    it "does not enqueue twice for the same account on consecutive runs" do
      described_class.perform_now

      expect { described_class.perform_now }.not_to have_enqueued_job(BackfillAdCreativesJob)
    end
  end

  describe "lookback" do
    it "syncs at least min_lookback_days back from today" do
      make_eligible(through: today)
      service = instance_double(AdCreativeBackfillService)
      allow(AdCreativeBackfillService).to receive(:new).and_return(service)

      expect(service).to receive(:sync_range).with(today - 6, today).and_return(true)

      described_class.perform_now(min_lookback_days: 7)
    end
  end

  describe "resilience" do
    it "skips an account whose token has expired" do
      ad_account.update_column(:token_expires_at, 1.day.ago)
      expect(AdCreativeBackfillService).not_to receive(:new)

      described_class.perform_now
    end

    it "continues to other accounts after one raises" do
      make_eligible(through: today)
      other = create(:ad_account, timezone: "UTC")
      other.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today)

      call_count = 0
      allow_any_instance_of(AdCreativeBackfillService).to receive(:sync_range) do
        call_count += 1
        raise StandardError, "boom" if call_count == 1
        true
      end

      described_class.perform_now

      expect(call_count).to eq(2)
    end

    it "scopes to one company when company_id is given" do
      other_company_account = create(:ad_account)
      other_company_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today)
      make_eligible(through: today)

      seen = []
      allow(AdCreativeBackfillService).to receive(:new) do |account|
        seen << account.id
        instance_double(AdCreativeBackfillService, sync_range: true)
      end

      described_class.perform_now(company_id: ad_account.company_id)

      expect(seen).to eq([ ad_account.id ])
    end
  end
end
