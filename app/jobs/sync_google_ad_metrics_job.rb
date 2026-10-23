class SyncGoogleAdMetricsJob < ApplicationJob
  queue_as :default

  # Conversions keep landing on past days for about a week.
  LOOKBACK_DAYS = 7

  # With no ids, the scheduled run over every Google account. company_id
  # narrows it to one company (the Ad Campaigns page's sync button);
  # ad_account_id to a single account — used right after it is connected, with
  # a long `days` to backfill its history.
  def perform(ad_account_id: nil, ad_account_ids: nil, company_id: nil, days: LOOKBACK_DAYS, trigger: "auto")
    scope = AdAccount.google
    scope = scope.where(id: ad_account_id) if ad_account_id
    scope = scope.where(id: ad_account_ids) if ad_account_ids
    scope = scope.where(company_id: company_id) if company_id

    scope.find_each do |account|
      if account.token_expired?
        SyncRun.record_failure(
          source: "google_ads", target: account, trigger: trigger,
          message: "Token expired — reconnect this ad account"
        )
        next
      end

      today = account.today_in_zone

      SyncRun.track(source: "google_ads", target: account, trigger: trigger) do
        service = GoogleAdsService.new(account)
        service.sync_date_range(today - days, today)
        service.sync_campaigns(today - days, today)
      end
    rescue => e
      Rails.logger.error("[SyncGoogleAdMetrics] account=#{account.account_id}: #{e.message}")
    end
  end
end
