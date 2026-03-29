class SyncShopifyMetricsJob < ApplicationJob
  queue_as :default

  def perform
    # This job will work after Feature 1 merges and ShopifyStore exists
    return unless defined?(ShopifyStore)

    ShopifyStore.find_each do |store|
      [ Date.yesterday, Date.current ].each do |date|
        ShopifyAnalyticsService.new(
          shop_domain: store.shop_domain,
          access_token: store.access_token,
          store_id: store.id,
          timezone: store.timezone
        ).sync_date(date)
      rescue => e
        Rails.logger.error("[SyncShopifyMetrics] store=#{store.shop_domain} date=#{date}: #{e.message}")
      end
    end
  end
end
