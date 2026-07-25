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
      inline_link_clicks: 4, video_3_sec_watched: 30,
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

    # Guards the reorder in run_backfill: the early-return-before-Meta-calls
    # fix must not accidentally starve mode A (coverage null, so
    # resolve_start_date can never return a date > today) of its Meta sync.
    it "still refreshes the token and syncs ad units even though the early return now runs first" do
      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today) ])

      service.call(days: 90)

      expect(meta).to have_received(:refresh_token_if_needed!)
      expect(meta).to have_received(:sync_ad_units)
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

  describe "caught-up account" do
    # A re-clicked sync on an account already caught up through today must
    # short-circuit before any Meta call: run_backfill checks
    # `start_date > today` (which needs only today_in_zone and the account's
    # own coverage columns) before calling refresh_token_if_needed! or
    # sync_ad_units. Previously those two Meta calls ran first, so every
    # re-click cost a real paged Meta /ads request even though the run itself
    # was a no-op.
    it "does not call sync_ad_units or refresh_token_if_needed! and still returns true" do
      ad_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today)

      expect(service.call(days: 90)).to be(true)

      expect(meta).not_to have_received(:refresh_token_if_needed!)
      expect(meta).not_to have_received(:sync_ad_units)
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

    # A mode A rebuild purges rows outside the new window. Without this, a
    # creative whose only spend was in the purged range keeps its old
    # first_spend_date, still reports anchor_state :ok, and renders $0.00 /
    # 0.0 ROAS instead of "—".
    it "clears first_spend_date once a rebuild leaves the creative with no spend" do
      creative = create(:ad_creative, ad_account: ad_account, first_spend_date: today - 200)
      unit = AdUnit.find_by(ad_id: "a1")
      unit.update!(ad_creative: creative)
      create(:ad_unit_daily_metric, ad_unit: unit, date: today - 200, spend: 5)
      allow(meta).to receive(:fetch_ad_insights).and_return([])

      service.call(days: 90)

      expect(creative.reload.first_spend_date).to be_nil
    end

    it "leaves another account's first_spend_date alone" do
      other_account = create(:ad_account)
      other_creative = create(:ad_creative, ad_account: other_account, first_spend_date: today - 10)
      allow(meta).to receive(:fetch_ad_insights).and_return([])

      service.call(days: 90)

      expect(other_creative.reload.first_spend_date).to eq(today - 10)
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
    # Regression guard for the composition bug: sync_ad_units used to run only
    # from #call, i.e. once at OAuth connect. persist_segment drops any row
    # whose ad_id has no ad_units record, so every ad created after onboarding
    # had all of its rows silently discarded and never appeared in the view.
    it "syncs ad units first, so an ad created after onboarding still lands" do
      ad_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today - 1)
      allow(meta).to receive(:sync_ad_units) { create(:ad_unit, ad_account: ad_account, ad_id: "brand-new-ad") }
      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today).merge(ad_id: "brand-new-ad") ])

      expect(service.sync_range(today, today)).to be(true)

      new_unit = AdUnit.find_by(ad_id: "brand-new-ad")
      expect(new_unit).to be_present
      expect(AdUnitDailyMetric.where(ad_unit_id: new_unit.id, date: today)).to exist
    end

    it "refreshes the token and backfills creative assets around the fetch" do
      ad_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today - 1)
      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today) ])

      service.sync_range(today, today)

      expect(meta).to have_received(:refresh_token_if_needed!)
      expect(meta).to have_received(:sync_creative_assets)
    end

    it "returns false instead of raising when syncing ad units hits Meta" do
      ad_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today - 1)
      allow(meta).to receive(:fetch_ad_insights).and_return([])
      allow(meta).to receive(:sync_ad_units).and_raise(Koala::Facebook::APIError.new(500, "boom"))
      allow(Rails.logger).to receive(:error)

      expect(service.sync_range(today, today)).to be(false)
      expect(meta).not_to have_received(:fetch_ad_insights)
    end

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
    # Pins the asymmetry between the two branches of persist_segment: the
    # initializing branch (mode A segment 0) must stay a plain assignment,
    # not the `[existing, to].compact.max` clamp the non-initializing branch
    # uses. Clamping here would let a stale, wider `_through_date` from
    # before the rebuild survive it — nothing else in this suite fails if
    # that clamp gets "tidied" back in, since a rebuild normally starts from
    # a narrower or nil `_through_date`. This account starts with
    # `_through_date` far in the future (today + 50) precisely so a clamp
    # would keep it instead of reducing it to segment 0's own window.
    it "reduces creative_synced_through_date on segment 0, rather than preserving a stale wider value" do
      ad_account.update_columns(creative_synced_from_date: nil, creative_synced_through_date: today + 50)
      calls = 0
      allow(meta).to receive(:fetch_ad_insights) do |_from, _to|
        calls += 1
        raise Koala::Facebook::APIError.new(500, "boom") if calls == 2
        []
      end

      service.call(days: 90)

      expect(ad_account.reload.creative_synced_through_date).to eq(today - 60)
    end

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

  describe "concurrency" do
    # A genuinely separate PostgreSQL session: transactional specs pin the
    # connection pool, so pool.checkout hands back the very same backend, and a
    # session-level advisory lock is re-entrant within one session — the assert
    # would pass vacuously. Closing the connection releases anything it holds.
    def with_separate_session
      raw = PG.connect(ActiveRecord::Base.connection.raw_connection.conninfo_hash.compact)
      yield raw
    ensure
      raw&.close
    end

    def try_lock(session)
      session.exec_params(
        "SELECT pg_try_advisory_lock($1, hashtext($2))",
        [ AdCreativeBackfillService::LOCK_NAMESPACE, ad_account.id ]
      ).getvalue(0, 0) == "t"
    end

    # The claim throttle only schedules; it is not a mutex. Two runs on one
    # account (manual button pressed during the connect-time backfill) would
    # let persist_segment move coverage backward and strand rows outside the
    # interval, with no purge to clean them up.
    it "refuses to start while another session holds the account's lock" do
      allow(meta).to receive(:fetch_ad_insights).and_return([])

      with_separate_session do |other|
        expect(try_lock(other)).to be(true)

        expect(service.call(days: 90)).to be(false)
        expect(meta).not_to have_received(:fetch_ad_insights)
        expect(ad_account.reload.creative_synced_through_date).to be_nil
      end
    end

    it "does not lock out a different ad account" do
      allow(meta).to receive(:fetch_ad_insights).and_return([])
      other_account = create(:ad_account, timezone: "UTC")

      with_separate_session do |other|
        other.exec_params(
          "SELECT pg_try_advisory_lock($1, hashtext($2))",
          [ AdCreativeBackfillService::LOCK_NAMESPACE, other_account.id ]
        )

        expect(service.call(days: 90)).to be(true)
      end
    end

    it "releases the lock after a run so the next one can claim it" do
      allow(meta).to receive(:fetch_ad_insights).and_return([])

      service.call(days: 90)

      with_separate_session { |other| expect(try_lock(other)).to be(true) }
    end

    it "releases the lock even when a segment raises" do
      allow(meta).to receive(:fetch_ad_insights) do |from, _to|
        [ row(from, spend: 10), row(from + 1, spend: -1) ]
      end

      expect { service.call(days: 90) }.to raise_error(ActiveRecord::RecordInvalid)

      with_separate_session { |other| expect(try_lock(other)).to be(true) }
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
