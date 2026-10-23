class SyncAdMetricsJob < ApplicationJob
  queue_as :default

  def perform(ad_account_ids: nil, trigger: "auto", sync_batch_id: nil)
    scope = AdAccount.meta
    scope = scope.where(id: ad_account_ids) if ad_account_ids

    scope.find_each do |account|
      if account.token_expired?
        SyncRun.record_failure(
          source: "meta_ads", target: account, trigger: trigger, batch_id: sync_batch_id,
          message: "Token expired — reconnect this ad account"
        )
        next
      end

      SyncRun.track(source: "meta_ads", target: account, trigger: trigger, batch_id: sync_batch_id) do
        service = MetaAdsService.new(account)
        service.refresh_token_if_needed!
        service.sync_date_range(2.days.ago.to_date, Date.current)
      end
    rescue => e
      Rails.logger.error("[SyncAdMetrics] account=#{account.account_id}: #{e.message}")
    end
  end
end
