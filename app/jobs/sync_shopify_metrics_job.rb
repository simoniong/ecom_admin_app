class SyncShopifyMetricsJob < ApplicationJob
  queue_as :default

  # days: number of past days to sync (default: 1 = yesterday + today)
  def perform(days: 1)
    return unless defined?(ShopifyStore)

    dates = (days.days.ago.to_date..Date.current).to_a

    ShopifyStore.find_each do |store|
      service = ShopifyAnalyticsService.new(
        shop_domain: store.shop_domain,
        access_token: store.access_token,
        store_id: store.id,
        timezone: store.timezone
      )

      dates.each do |date|
        service.sync_date(date)
      rescue => e
        Rails.logger.error("[SyncShopifyMetrics] store=#{store.shop_domain} date=#{date}: #{e.message}")
      end
    end
  end
end
