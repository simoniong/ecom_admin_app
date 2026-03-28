class RefreshMetaTokensJob < ApplicationJob
  queue_as :default

  def perform
    AdAccount.meta.where("token_expires_at < ?", 7.days.from_now).find_each do |account|
      MetaAdsService.new(account).refresh_token_if_needed!
    rescue => e
      Rails.logger.error("[RefreshMetaTokens] account=#{account.account_id}: #{e.message}")
    end
  end
end
