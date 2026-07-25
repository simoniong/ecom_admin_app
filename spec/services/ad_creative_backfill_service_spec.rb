require "rails_helper"

RSpec.describe AdCreativeBackfillService do
  let(:ad_account) { create(:ad_account, timezone: "UTC") }
  let(:meta) { instance_double(MetaAdsService) }
  let(:service) { described_class.new(ad_account, meta_service: meta) }
  let(:today) { Date.new(2026, 7, 25) }

  before do
    allow(meta).to receive(:refresh_token_if_needed!)
    allow(meta).to receive(:sync_ad_units)
    allow(meta).to receive(:sync_creative_assets)
    allow(ad_account).to receive(:today_in_zone).and_return(today)
    create(:ad_unit, ad_account: ad_account, ad_id: "a1")
  end

  def row(date, spend: 10, purchases: 1, value: 20)
    { ad_id: "a1", date: date, spend: spend, impressions: 100, clicks: 5,
      inline_link_clicks: 4, video_continuous_2_sec_watched: 30,
      video_p25_watched: 25, video_p50_watched: 15, video_p75_watched: 9,
      video_p95_watched: 5, video_p100_watched: 4, add_to_cart: 2,
      checkout_initiated: 1, purchases: purchases, conversion_value: value }
  end

  describe "mode A (initialize)" do
    it "sets both coverage bounds and spans the full window" do
      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today) ])

      service.call(days: 90)

      ad_account.reload
      expect(ad_account.creative_synced_from_date).to eq(today - 89)
      expect(ad_account.creative_synced_through_date).to eq(today)
    end

    it "runs when only one bound is null" do
      ad_account.update_columns(creative_synced_from_date: today - 10, creative_synced_through_date: nil)
      allow(meta).to receive(:fetch_ad_insights).and_return([])

      service.call(days: 90)

      expect(ad_account.reload.creative_synced_from_date).to eq(today - 89)
    end

    it "chunks the window into 30-day segments oldest first" do
      ranges = []
      allow(meta).to receive(:fetch_ad_insights) { |from, to| ranges << [ from, to ]; [] }

      service.call(days: 90)

      expect(ranges.size).to eq(3)
      expect(ranges.first.first).to eq(today - 89)
      expect(ranges.last.last).to eq(today)
      expect(ranges).to eq(ranges.sort_by(&:first))
    end
  end

  describe "mode B (forward resume)" do
    it "resumes from the day after the current through date" do
      ad_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today - 5)
      ranges = []
      allow(meta).to receive(:fetch_ad_insights) { |from, to| ranges << [ from, to ]; [] }

      service.call(days: 90)

      expect(ranges.first.first).to eq(today - 4)
      expect(ad_account.reload.creative_synced_from_date).to eq(today - 89)
      expect(ad_account.reload.creative_synced_through_date).to eq(today)
    end

    it "never purges rows outside the newly fetched segment" do
      ad_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today - 5)
      old_metric = create(:ad_unit_daily_metric, ad_unit: AdUnit.find_by(ad_id: "a1"), date: today - 89, spend: 5)
      allow(meta).to receive(:fetch_ad_insights).and_return([])

      service.call(days: 90)

      expect(AdUnitDailyMetric.exists?(old_metric.id)).to be(true)
    end
  end

  describe "segment failure" do
    it "aborts the run, keeps earlier segments and never sends later ones" do
      calls = []
      allow(meta).to receive(:fetch_ad_insights) do |from, to|
        calls << [ from, to ]
        raise Koala::Facebook::APIError.new(500, "boom") if calls.size == 2
        []
      end

      expect(service.call(days: 90)).to be(false)

      expect(calls.size).to eq(2)
      expect(ad_account.reload.creative_synced_through_date).to eq(today - 60)
    end

    it "never leaves metric rows outside the coverage interval" do
      calls = []
      allow(meta).to receive(:fetch_ad_insights) do |from, to|
        calls << [ from, to ]
        raise Koala::Facebook::APIError.new(500, "boom") if calls.size == 2
        [ row(from) ]
      end

      service.call(days: 90)

      ad_account.reload
      dates = AdUnitDailyMetric.joins(:ad_unit).where(ad_units: { ad_account_id: ad_account.id }).pluck(:date)
      expect(dates).to all(be_between(ad_account.creative_synced_from_date, ad_account.creative_synced_through_date))
    end
  end

  describe "first_spend_date" do
    it "records the earliest day with spend above zero" do
      creative = create(:ad_creative, ad_account: ad_account)
      AdUnit.find_by(ad_id: "a1").update!(ad_creative: creative)
      allow(meta).to receive(:fetch_ad_insights).and_return([
        row(today - 3, spend: 0), row(today - 2, spend: 5), row(today - 1, spend: 7)
      ])

      service.call(days: 90)

      expect(creative.reload.first_spend_date).to eq(today - 2)
    end

    it "leaves first_spend_date null when the creative never spent" do
      creative = create(:ad_creative, ad_account: ad_account)
      AdUnit.find_by(ad_id: "a1").update!(ad_creative: creative)
      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today, spend: 0) ])

      service.call(days: 90)

      expect(creative.reload.first_spend_date).to be_nil
    end
  end

  describe "upsert" do
    it "updates an existing row rather than duplicating it via sync_range" do
      ad_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today - 1)

      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today, spend: 10) ])
      service.sync_range(today, today)

      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today, spend: 99) ])
      service.sync_range(today, today)

      metrics = AdUnitDailyMetric.joins(:ad_unit).where(ad_units: { ad_account_id: ad_account.id })
      expect(metrics.count).to eq(1)
      expect(metrics.first.spend).to eq(99)
    end

    it "ignores rows for ads that are not synced yet and logs how many were skipped" do
      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today).merge(ad_id: "unknown") ])
      allow(Rails.logger).to receive(:warn)

      expect { service.call(days: 90) }.not_to change(AdUnitDailyMetric, :count)

      expect(Rails.logger).to have_received(:warn).with(a_string_including("skipped 1 row"))
    end
  end

  describe "sync_range" do
    it "refuses to run and logs a warning when coverage bounds are not yet established" do
      expect(meta).not_to receive(:fetch_ad_insights)
      allow(Rails.logger).to receive(:warn)

      result = service.sync_range(today, today)

      expect(result).to be(false)
      expect(AdUnitDailyMetric.count).to eq(0)
      expect(Rails.logger).to have_received(:warn).with(a_string_including("coverage bounds not established"))
    end
  end

  describe "mode A rebuild" do
    it "purges pre-existing metric rows that fall outside the rebuilt window" do
      stale_unit = AdUnit.find_by(ad_id: "a1")
      stale_metric = create(:ad_unit_daily_metric, ad_unit: stale_unit, date: today - 200, spend: 5)
      allow(meta).to receive(:fetch_ad_insights).and_return([])

      service.call(days: 90)

      expect(AdUnitDailyMetric.exists?(stale_metric.id)).to be(false)
    end

    it "leaves no row outside the committed interval when a later segment fails, even for a stray row inside the not-yet-reached window" do
      stray_unit = AdUnit.find_by(ad_id: "a1")
      # today - 30 sits inside segment 1's own range (today-59..today-30), the
      # segment that fails below — it must not survive past segment 1's purge.
      stray_metric = create(:ad_unit_daily_metric, ad_unit: stray_unit, date: today - 30, spend: 5)

      calls = []
      allow(meta).to receive(:fetch_ad_insights) do |from, to|
        calls << [ from, to ]
        raise Koala::Facebook::APIError.new(500, "boom") if calls.size == 2
        []
      end

      result = service.call(days: 90)

      expect(result).to be(false)
      ad_account.reload
      expect(AdUnitDailyMetric.exists?(stray_metric.id)).to be(false)
      dates = AdUnitDailyMetric.joins(:ad_unit).where(ad_units: { ad_account_id: ad_account.id }).pluck(:date)
      expect(dates).to all(be_between(ad_account.creative_synced_from_date, ad_account.creative_synced_through_date))
    end
  end

  describe "transactional integrity" do
    it "rolls back the whole segment, including the coverage advance, when a row fails validation" do
      allow(meta).to receive(:fetch_ad_insights) do |from, _to|
        [ row(from, spend: 10), row(from + 1, spend: -1) ]
      end

      expect { service.call(days: 90) }.to raise_error(ActiveRecord::RecordInvalid)

      expect(AdUnitDailyMetric.count).to eq(0)
      ad_account.reload
      expect(ad_account.creative_synced_from_date).to be_nil
      expect(ad_account.creative_synced_through_date).to be_nil
    end
  end
end
