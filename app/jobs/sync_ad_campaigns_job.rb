class SyncAdCampaignsJob < ApplicationJob
  queue_as :default

  # company_id: optional — scope sync to one company; nil = all companies
  # days: number of past days of insights to sync (default: 2 for timezone safety)
  def perform(company_id: nil, days: 2)
    scope = AdAccount.meta
    scope = scope.where(company_id: company_id) if company_id
    scope.find_each do |account|
      next if account.token_expired?

      service = MetaAdsService.new(account)
      service.refresh_token_if_needed!
      service.sync_campaigns
      service.sync_campaign_insights(days.days.ago.to_date, Date.current)
    rescue => e
      Rails.logger.error("[SyncAdCampaigns] account=#{account.account_id}: #{e.message}")
    end
  end
end
