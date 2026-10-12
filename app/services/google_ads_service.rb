# Pulls a Google Ads account's daily figures into the tables the app already
# reads for Meta: account-level totals into ad_daily_metrics (summed by
# DashboardMetricsService for ad spend, ROAS and CPA) and per-campaign totals
# into ad_campaigns / ad_campaign_daily_metrics (the Ad Campaigns page).
class GoogleAdsService
  CAMPAIGN_FIELDS = "campaign.id, campaign.name, campaign.status, campaign_budget.amount_micros".freeze
  METRIC_FIELDS = "segments.date, metrics.cost_micros, metrics.clicks, metrics.impressions, " \
                  "metrics.conversions, metrics.conversions_value".freeze

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
    rows = search("SELECT #{METRIC_FIELDS} FROM customer WHERE #{date_filter(start_date, end_date)}")

    AdDailyMetric.transaction do
      dates = rows.map do |row|
        date = Date.iso8601(row.dig("segments", "date"))
        metric = @ad_account.ad_daily_metrics.find_or_initialize_by(date: date)
        m = row["metrics"] || {}
        metric.update!(
          spend: money(m["costMicros"]),
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
  end

  # Campaigns and their daily figures, with the same restate-and-zero rule as
  # sync_date_range. Two searches: the daily one only returns campaign/day
  # pairs with activity, so the campaign list itself comes from a second,
  # unsegmented search — otherwise a paused campaign with no spend in range
  # would never appear. Removed campaigns are only kept when they spent.
  def sync_campaigns(start_date, end_date)
    listed = search("SELECT #{CAMPAIGN_FIELDS} FROM campaign WHERE campaign.status != 'REMOVED'")
    daily = search("SELECT #{CAMPAIGN_FIELDS}, #{METRIC_FIELDS} FROM campaign WHERE #{date_filter(start_date, end_date)}")

    AdCampaign.transaction do
      campaigns = (listed + daily).uniq { |row| row.dig("campaign", "id") }.to_h do |row|
        [ row.dig("campaign", "id"), save_campaign(row) ]
      end

      synced_ids = daily.map do |row|
        campaign = campaigns.fetch(row.dig("campaign", "id"))
        metric = campaign.ad_campaign_daily_metrics.find_or_initialize_by(date: Date.iso8601(row.dig("segments", "date")))
        m = row["metrics"] || {}
        metric.update!(
          spend: money(m["costMicros"]),
          clicks: m["clicks"].to_i,
          impressions: m["impressions"].to_i,
          purchases: m["conversions"].to_f.round,
          conversion_value: BigDecimal(m["conversionsValue"].to_s.presence || "0").round(2)
        )
        metric.id
      end

      AdCampaignDailyMetric.where(ad_campaign: @ad_account.ad_campaigns, date: start_date..end_date)
                           .where.not(id: synced_ids)
                           .update_all(spend: 0, clicks: 0, impressions: 0, purchases: 0, conversion_value: 0, updated_at: Time.current)
    end
  end

  private

  def search(query)
    @api.search(@ad_account.account_id, query)
  rescue GoogleAdsApi::AuthError
    # Revoked or expired refresh token: mark the account so the UI asks for a
    # reconnect and the scheduled sync stops retrying it.
    @ad_account.update_columns(token_expires_at: Time.current)
    raise
  end

  def date_filter(start_date, end_date)
    "segments.date BETWEEN '#{start_date.iso8601}' AND '#{end_date.iso8601}'"
  end

  def save_campaign(row)
    campaign = @ad_account.ad_campaigns.find_or_initialize_by(campaign_id: row.dig("campaign", "id"))
    campaign.update!(
      campaign_name: row.dig("campaign", "name"),
      status: map_status(row.dig("campaign", "status")),
      daily_budget: money(row.dig("campaignBudget", "amountMicros"))
    )
    campaign
  end

  def map_status(status)
    case status
    when "ENABLED" then "active"
    when "REMOVED" then "deleted"
    else "paused"
    end
  end

  # Google amounts are in the account's currency, millionths of a unit.
  def money(micros)
    (BigDecimal(micros.to_s.presence || "0") / 1_000_000).round(2)
  end
end
