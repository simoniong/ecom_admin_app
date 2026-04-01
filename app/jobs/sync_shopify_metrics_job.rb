class SyncShopifyMetricsJob < ApplicationJob
  queue_as :default

  # days: number of past days to sync (default: 1 = yesterday + today in shop timezone)
  def perform(days: 1)
    shopify_store_klass = "ShopifyStore".safe_constantize
    return unless shopify_store_klass

    shopify_store_klass.find_each do |store|
      shop_tz = ActiveSupport::TimeZone[store.timezone] || ActiveSupport::TimeZone["UTC"]
      shop_today = Time.current.in_time_zone(shop_tz).to_date
      dates = ((shop_today - days.days)..shop_today).to_a

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
