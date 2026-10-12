# Pulls a Google Ads account's daily account-level totals into
# ad_daily_metrics — the table DashboardMetricsService sums for ad spend, ROAS
# and CPA, so Google spend counts next to Meta's without any dashboard change.
class GoogleAdsService
  def initialize(ad_account, api: nil)
    @ad_account = ad_account
    @api = api || GoogleAdsApi.new(refresh_token: ad_account.access_token,
                                   login_customer_id: ad_account.login_customer_id)
  end

  # Re-reads the whole range each time: Google keeps attributing conversions
  # to past days and corrects spend for invalid clicks, so a day isn't final
  # when it ends. A day the API no longer reports any activity for is zeroed
  # rather than left holding its old figures.
  def sync_date_range(start_date, end_date)
    rows = @api.search(@ad_account.account_id,
                       "SELECT segments.date, metrics.cost_micros, metrics.clicks, metrics.impressions, " \
                       "metrics.conversions, metrics.conversions_value FROM customer " \
                       "WHERE segments.date BETWEEN '#{start_date.iso8601}' AND '#{end_date.iso8601}'")

    AdDailyMetric.transaction do
      dates = rows.map do |row|
        date = Date.iso8601(row.dig("segments", "date"))
        m = row["metrics"] || {}
        metric = @ad_account.ad_daily_metrics.find_or_initialize_by(date: date)
        metric.update!(
          # cost_micros is in the account's currency, millionths of a unit.
          spend: (BigDecimal(m["costMicros"].to_s.presence || "0") / 1_000_000).round(2),
          clicks: m["clicks"].to_i,
          impressions: m["impressions"].to_i,
          # Google reports fractional (data-driven) conversions; the column is
          # an integer count like Meta's.
          conversions: m["conversions"].to_f.round,
          conversion_value: BigDecimal(m["conversionsValue"].to_s.presence || "0").round(2)
        )
        date
      end

      @ad_account.ad_daily_metrics.where(date: start_date..end_date).where.not(date: dates)
                 .update_all(spend: 0, clicks: 0, impressions: 0, conversions: 0, conversion_value: 0, updated_at: Time.current)
    end
  rescue GoogleAdsApi::AuthError
    # Revoked or expired refresh token: mark the account so the UI asks for a
    # reconnect and the scheduled sync stops retrying it.
    @ad_account.update_columns(token_expires_at: Time.current)
    raise
  end
end
