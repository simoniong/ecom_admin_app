class SyncAdMetricsJob < ApplicationJob
  queue_as :default

  def perform
    AdAccount.meta.find_each do |account|
      next if account.token_expired?

      service = MetaAdsService.new(account)
      service.refresh_token_if_needed!
      service.sync_date_range(2.days.ago.to_date, Date.current)
    rescue => e
      Rails.logger.error("[SyncAdMetrics] account=#{account.account_id}: #{e.message}")
    end
  end
end
