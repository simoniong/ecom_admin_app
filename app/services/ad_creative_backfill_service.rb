class AdCreativeBackfillService
  SEGMENT_DAYS = 30

  # Advisory-lock namespace, so this key space cannot collide with any other
  # advisory lock taken elsewhere in the app. The second key is derived from
  # the ad account id.
  LOCK_NAMESPACE = 8_242_611

  def initialize(ad_account, meta_service: nil)
    @ad_account = ad_account
    @meta = meta_service || MetaAdsService.new(ad_account)
  end

  # Returns true when every segment succeeded, false when the run aborted or
  # another run for this account is already in flight.
  #
  # `claim_backfill_slot!` is a *scheduling* throttle, not a mutex: the manual
  # sync button and the connect-time backfill can both target one account, and
  # two concurrent runs would let `persist_segment` move coverage backward and
  # strand rows outside the interval (§5.6). The advisory lock is the mutex.
  def call(days: 90)
    return false unless acquire_lock

    begin
      run_backfill(days: days)
    ensure
      release_lock
    end
  end

  # Used by the rolling job: one segment, forward append only. Must never run
  # against an account whose coverage interval is not yet established — that
  # would write rows and advance `_through_date` while `_from_date` stays
  # null, violating the "no rows while either bound is null" rule (§5.6).
  # Task 6 also gates eligibility externally, but this method is public and
  # must not depend on that.
  def sync_range(start_date, end_date)
    if coverage_incomplete?
      Rails.logger.warn("[AdCreativeRolling] account=#{@ad_account.account_id}: refusing sync_range, coverage bounds not established")
      return false
    end

    # `sync_ad_units` must run on EVERY rolling pass, not just at connect time:
    # `persist_segment` drops any insight row whose `ad_id` has no `ad_units`
    # row, so an ad created after onboarding would have all of its daily rows
    # silently discarded, its creative never inserted, and it would never
    # appear in the view. `SyncAdCampaignsJob` does the same thing (sync the
    # entities, then their insights) for campaigns. `refresh_token_if_needed!`
    # first, per §5.2 — the rolling path is one of the two jobs that must.
    # All of it sits inside the rescue so a Meta failure still returns false.
    @meta.refresh_token_if_needed!
    @meta.sync_ad_units

    rows = @meta.fetch_ad_insights(start_date, end_date)
    persist_segment(rows, start_date, end_date, initialize_bounds: false)
    # After a successful persist, so newly discovered videos get their
    # thumbnails and durations instead of waiting for the next backfill.
    @meta.sync_creative_assets
    true
  rescue Koala::Facebook::APIError, Koala::Facebook::ClientError => e
    Rails.logger.error("[AdCreativeRolling] account=#{@ad_account.account_id}: #{e.message}")
    false
  end

  private

  def run_backfill(days:)
    @meta.refresh_token_if_needed!
    @meta.sync_ad_units

    today = @ad_account.today_in_zone
    start_date = resolve_start_date(today, days)

    # An already-caught-up (or ahead-of-today, e.g. a westward timezone change
    # narrowing `today_in_zone`) account is not a backfill scenario — rolling
    # sync owns [today-1, today] per design §5.6. Do nothing rather than
    # shrinking `creative_synced_through_date` backward.
    return true if start_date > today

    initializing = coverage_incomplete?
    # Only set (and only ever read) in mode A: the rebuild window's start,
    # held constant across every segment so each segment's purge can bound
    # its lower edge without drifting. Mode B leaves this nil, which is what
    # keeps the purge from ever touching mode B's history (see persist_segment).
    rebuild_start_date = start_date if initializing

    segments(start_date, today).each_with_index do |(from, to), index|
      first_segment = initializing && index.zero?
      rows = @meta.fetch_ad_insights(from, to)
      persist_segment(rows, from, to, initialize_bounds: first_segment, purge_from: rebuild_start_date)
    rescue Koala::Facebook::APIError, Koala::Facebook::ClientError => e
      Rails.logger.error("[AdCreativeBackfill] account=#{@ad_account.account_id} segment=#{from}..#{to}: #{e.message}")
      return false
    end

    @meta.sync_creative_assets
    true
  end

  # Session-level (not transaction-scoped) because `call` deliberately commits
  # one transaction per segment; a xact lock would force the whole 90-day run
  # into a single transaction. Released in `call`'s ensure, so an exception
  # cannot leak it; a dead connection releases it too.
  def acquire_lock
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT pg_try_advisory_lock(?, hashtext(?))", LOCK_NAMESPACE, @ad_account.id ]
      )
    )
  end

  def release_lock
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT pg_advisory_unlock(?, hashtext(?))", LOCK_NAMESPACE, @ad_account.id ]
      )
    )
  end

  def coverage_incomplete?
    @ad_account.creative_synced_from_date.nil? || @ad_account.creative_synced_through_date.nil?
  end

  # Mode A when either bound is null (a half-null state is corruption; the only
  # safe response is a full rebuild). Mode B otherwise. Mode C is out of scope.
  def resolve_start_date(today, days)
    return today - (days - 1) if coverage_incomplete?

    @ad_account.creative_synced_through_date + 1
  end

  def segments(start_date, end_date)
    result = []
    cursor = start_date
    while cursor <= end_date
      stop = [ cursor + (SEGMENT_DAYS - 1), end_date ].min
      result << [ cursor, stop ]
      cursor = stop + 1
    end
    result
  end

  # Metric writes and the coverage advance share one transaction so the
  # invariant can never be observed broken (spec §5.6). `purge_from` is only
  # set in mode A (see `call`) — every mode A segment purges this account's
  # rows outside `[purge_from, to]`, i.e. outside the window coverage has
  # actually reached so far, not the full target window. That way the
  # invariant holds after every transaction, including right after an abort:
  # rows in a not-yet-fetched later segment get deleted here and re-fetched
  # only once their own segment actually runs. Bounding by `purge_from`
  # (the rebuild's start, held constant) rather than `from` (this segment's
  # own start) matters only for mode A, where they happen to coincide on
  # segment 0 and diverge from then on; mode B never passes `purge_from` at
  # all, so it can never purge — a purge bounded by mode B's own `from`
  # (`_through_date + 1`) would otherwise delete the account's entire history.
  def persist_segment(rows, from, to, initialize_bounds:, purge_from: nil)
    unit_ids = @ad_account.ad_units.pluck(:ad_id, :id).to_h

    ActiveRecord::Base.transaction do
      if purge_from
        AdUnitDailyMetric
          .joins(:ad_unit)
          .where(ad_units: { ad_account_id: @ad_account.id })
          .where.not(date: purge_from..to)
          .delete_all
      end

      skipped = 0
      rows.each do |row|
        # Trust our own segment bounds over Meta's `date_start`, so "no row
        # lands outside the segment" holds by construction.
        next unless row[:date].between?(from, to)

        unit_id = unit_ids[row[:ad_id]]
        if unit_id.nil?
          skipped += 1
          next
        end

        metric = AdUnitDailyMetric.find_or_initialize_by(ad_unit_id: unit_id, date: row[:date])
        metric.assign_attributes(row.except(:ad_id, :date))
        metric.save!
      end

      if skipped.positive?
        Rails.logger.warn("[AdCreativeBackfill] account=#{@ad_account.account_id} segment=#{from}..#{to}: skipped #{skipped} row(s) with unknown ad_id")
      end

      if initialize_bounds
        # Mode A segment 0 deliberately assigns both bounds outright: this is
        # the transaction that (re)establishes the interval, and clamping it
        # would keep a stale, wider `_through_date` alive with no rows behind it.
        @ad_account.update!(creative_synced_from_date: from, creative_synced_through_date: to)
      else
        # A no-op under a single writer (segments run oldest→newest), but if two
        # runs for one account ever interleave, this turns a silent coverage
        # regression — which would strand rows outside the interval with no
        # purge to clean them up — into a harmless no-op.
        @ad_account.update!(
          creative_synced_through_date: [ @ad_account.creative_synced_through_date, to ].compact.max
        )
      end

      recompute_first_spend_dates
    end
  end

  # Anchored on AdUnit.attributable (multi_asset: false AND creative present)
  # to match Task 8's view scope — a multi_asset unit carrying a creative id
  # must not anchor that creative's first_spend_date.
  def recompute_first_spend_dates
    earliest = AdUnitDailyMetric
      .joins(:ad_unit)
      .merge(AdUnit.attributable)
      .where(ad_units: { ad_account_id: @ad_account.id })
      .where("ad_unit_daily_metrics.spend > 0")
      .group("ad_units.ad_creative_id")
      .minimum("ad_unit_daily_metrics.date")

    earliest.each do |creative_id, date|
      AdCreative.where(id: creative_id).update_all(first_spend_date: date)
    end

    # Setting is not enough: a creative whose positive-spend rows just got
    # purged (mode A rebuild) or overwritten to zero keeps a stale
    # `first_spend_date`, which makes `anchor_state` report `:ok` and renders
    # $0.00 / 0.0 ROAS instead of "—". Anything with no positive-spend row left
    # inside the coverage interval must go back to null.
    stale = AdCreative.where(ad_account_id: @ad_account.id).where.not(first_spend_date: nil)
    stale = stale.where.not(id: earliest.keys) if earliest.any?
    stale.update_all(first_spend_date: nil)
  end
end
