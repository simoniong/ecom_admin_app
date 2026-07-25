class AdCreativeBackfillService
  SEGMENT_DAYS = 30

  def initialize(ad_account, meta_service: nil)
    @ad_account = ad_account
    @meta = meta_service || MetaAdsService.new(ad_account)
  end

  # Returns true when every segment succeeded, false when the run aborted.
  def call(days: 90)
    @meta.refresh_token_if_needed!
    @meta.sync_ad_units

    today = @ad_account.today_in_zone
    start_date = resolve_start_date(today, days)
    # Clamp rather than skip: even when coverage already reaches `today`,
    # re-sync today's (still-accumulating) segment instead of no-op'ing, so a
    # same-day re-run picks up late-arriving spend/conversions.
    start_date = today if start_date > today

    initializing = coverage_incomplete?

    segments(start_date, today).each_with_index do |(from, to), index|
      rows = @meta.fetch_ad_insights(from, to)
      persist_segment(rows, from, to, initialize_bounds: initializing && index.zero?)
    rescue Koala::Facebook::APIError, Koala::Facebook::ClientError => e
      Rails.logger.error("[AdCreativeBackfill] account=#{@ad_account.account_id} segment=#{from}..#{to}: #{e.message}")
      return false
    end

    @meta.sync_creative_assets
    true
  end

  # Used by the rolling job: one segment, forward append only.
  def sync_range(start_date, end_date)
    rows = @meta.fetch_ad_insights(start_date, end_date)
    persist_segment(rows, start_date, end_date, initialize_bounds: false)
    true
  rescue Koala::Facebook::APIError, Koala::Facebook::ClientError => e
    Rails.logger.error("[AdCreativeRolling] account=#{@ad_account.account_id}: #{e.message}")
    false
  end

  private

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
  # invariant can never be observed broken (spec §5.6).
  def persist_segment(rows, from, to, initialize_bounds:)
    unit_ids = @ad_account.ad_units.pluck(:ad_id, :id).to_h

    ActiveRecord::Base.transaction do
      rows.each do |row|
        unit_id = unit_ids[row[:ad_id]]
        next if unit_id.nil?

        metric = AdUnitDailyMetric.find_or_initialize_by(ad_unit_id: unit_id, date: row[:date])
        metric.assign_attributes(row.except(:ad_id, :date))
        metric.save!
      end

      if initialize_bounds
        @ad_account.update!(creative_synced_from_date: from, creative_synced_through_date: to)
      else
        @ad_account.update!(creative_synced_through_date: to)
      end

      recompute_first_spend_dates
    end
  end

  def recompute_first_spend_dates
    earliest = AdUnitDailyMetric
      .joins(:ad_unit)
      .where(ad_units: { ad_account_id: @ad_account.id })
      .where("ad_units.ad_creative_id IS NOT NULL")
      .where("ad_unit_daily_metrics.spend > 0")
      .group("ad_units.ad_creative_id")
      .minimum("ad_unit_daily_metrics.date")

    earliest.each do |creative_id, date|
      AdCreative.where(id: creative_id).update_all(first_spend_date: date)
    end
  end
end
