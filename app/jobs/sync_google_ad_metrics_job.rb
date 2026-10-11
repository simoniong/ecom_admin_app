class SyncGoogleAdMetricsJob < ApplicationJob
  queue_as :default

  # Conversions keep landing on past days for about a week.
  LOOKBACK_DAYS = 7

  # With no account id, the scheduled run over every Google account. With one,
  # a single account — used right after it is connected, with a long `days`
  # to backfill its history.
  def perform(ad_account_id: nil, days: LOOKBACK_DAYS)
    scope = AdAccount.google
    scope = scope.where(id: ad_account_id) if ad_account_id

    scope.find_each do |account|
      next if account.token_expired?

      today = account.today_in_zone
      GoogleAdsService.new(account).sync_date_range(today - days, today)
    rescue => e
      Rails.logger.error("[SyncGoogleAdMetrics] account=#{account.account_id}: #{e.message}")
    end
  end
end
