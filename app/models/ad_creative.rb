class AdCreative < ApplicationRecord
  ASSET_TYPES = %w[video image].freeze

  belongs_to :ad_account
  # nullify, not destroy: an ad going away must not delete the creative record
  has_many :ad_units, dependent: :nullify

  validates :asset_type, presence: true, inclusion: { in: ASSET_TYPES }
  validates :asset_id, presence: true,
    uniqueness: { scope: [ :ad_account_id, :asset_type ] }

  scope :video, -> { where(asset_type: "video") }

  # Ordered and total. The order is load-bearing: the conditions overlap, and a
  # truncated anchor makes a number WRONG rather than merely incomplete, so it
  # must outrank :insufficient (spec §6.3).
  #
  # window_days nil means the lifetime window, which has no length to check.
  def anchor_state(window_days)
    return :no_spend if first_spend_date.nil?

    from = ad_account.creative_synced_from_date
    through = ad_account.creative_synced_through_date
    return :unsynced if from.nil? || through.nil?
    return :truncated if first_spend_date <= from

    # Unreachable for window_days == 1 while the coverage invariant holds. Kept
    # deliberately: it is the only guard if the invariant is ever broken.
    return :insufficient if window_days.present? && first_spend_date + (window_days - 1) > through

    :ok
  end

  CreativeMetrics = Struct.new(
    :impressions, :inline_link_clicks,
    :video_continuous_2_sec_watched, :video_p50_watched, :video_p75_watched,
    :d1_spend, :d1_purchases,
    :d3_spend, :d3_value, :d5_spend, :d5_value,
    :lifetime_spend, :lifetime_value
  ) do
    def two_sec_rate = percentage(video_continuous_2_sec_watched, impressions)
    def p50_rate = percentage(video_p50_watched, impressions)
    def p75_rate = percentage(video_p75_watched, impressions)
    def link_ctr = percentage(inline_link_clicks, impressions)
    def d3_roas = ratio(d3_value, d3_spend)
    def d5_roas = ratio(d5_value, d5_spend)
    def lifetime_roas = ratio(lifetime_value, lifetime_spend)

    private

    def percentage(numerator, denominator)
      return 0 if denominator.to_i.zero?

      (numerator.to_f / denominator * 100).round(2)
    end

    def ratio(numerator, denominator)
      return 0 if denominator.to_f.zero?

      (numerator.to_f / denominator.to_f).round(2)
    end
  end

  def self.batch_aggregated_metrics(creative_ids, date_range)
    # Coerce defensively: a caller passing records (or a relation) rather than
    # bare ids would otherwise silently key the returned hash on model objects
    # while the pluck'ed totals are keyed on ids, so every lookup misses and
    # every metric renders as zero with no error raised.
    ids = Array(creative_ids).map { |c| c.try(:id) || c }
    return {} if ids.empty?

    range = range_totals(ids, date_range)
    anchored = { 1 => anchor_totals(ids, 1), 3 => anchor_totals(ids, 3), 5 => anchor_totals(ids, 5) }
    lifetime = lifetime_totals(ids)

    ids.index_with do |id|
      r = range[id] || {}
      d1 = anchored[1][id] || {}
      d3 = anchored[3][id] || {}
      d5 = anchored[5][id] || {}
      lt = lifetime[id] || {}

      CreativeMetrics.new(
        r[:impressions].to_i, r[:inline_link_clicks].to_i,
        r[:two_sec].to_i, r[:p50].to_i, r[:p75].to_i,
        d1[:spend].to_f, d1[:purchases].to_i,
        d3[:spend].to_f, d3[:value].to_f,
        d5[:spend].to_f, d5[:value].to_f,
        lt[:spend].to_f, lt[:value].to_f
      )
    end
  end

  # Only attributable units count: multi_asset ads cannot be assigned to one
  # creative, so their spend must never land in a creative's numbers. Reuses
  # AdUnit.attributable rather than re-stating `multi_asset: false` inline so
  # the two definitions of "attributable" cannot drift apart.
  def self.metrics_join
    joins("INNER JOIN ad_units ON ad_units.ad_creative_id = ad_creatives.id")
      .joins("INNER JOIN ad_unit_daily_metrics ON ad_unit_daily_metrics.ad_unit_id = ad_units.id")
      .merge(AdUnit.attributable)
  end
  private_class_method :metrics_join

  def self.range_totals(ids, date_range)
    metrics_join
      .where(id: ids, ad_unit_daily_metrics: { date: date_range })
      .group("ad_creatives.id")
      .pluck(
        Arel.sql("ad_creatives.id"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.impressions), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.inline_link_clicks), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.video_continuous_2_sec_watched), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.video_p50_watched), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.video_p75_watched), 0)")
      )
      .to_h { |row| [ row[0], { impressions: row[1], inline_link_clicks: row[2], two_sec: row[3], p50: row[4], p75: row[5] } ] }
  end
  private_class_method :range_totals

  def self.anchor_totals(ids, window_days)
    metrics_join
      .where(id: ids)
      .where("ad_unit_daily_metrics.date BETWEEN ad_creatives.first_spend_date " \
             "AND ad_creatives.first_spend_date + CAST(? AS integer)", window_days - 1)
      .group("ad_creatives.id")
      .pluck(
        Arel.sql("ad_creatives.id"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.spend), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.conversion_value), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.purchases), 0)")
      )
      .to_h { |row| [ row[0], { spend: row[1], value: row[2], purchases: row[3] } ] }
  end
  private_class_method :anchor_totals

  # Explicitly bounded by the coverage interval. Under the invariant this equals
  # "all synced days", but carrying the bound means a broken invariant can only
  # under-count, never silently inflate a lifetime figure (spec §6.3).
  def self.lifetime_totals(ids)
    metrics_join
      .joins("INNER JOIN ad_accounts ON ad_accounts.id = ad_creatives.ad_account_id")
      .where(id: ids)
      .where("ad_unit_daily_metrics.date BETWEEN ad_accounts.creative_synced_from_date " \
             "AND ad_accounts.creative_synced_through_date")
      .group("ad_creatives.id")
      .pluck(
        Arel.sql("ad_creatives.id"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.spend), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.conversion_value), 0)")
      )
      .to_h { |row| [ row[0], { spend: row[1], value: row[2] } ] }
  end
  private_class_method :lifetime_totals
end
