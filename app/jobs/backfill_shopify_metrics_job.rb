class BackfillShopifyMetricsJob < ApplicationJob
  queue_as :default

  def perform(shopify_store_id, days: 90)
    store = ShopifyStore.find_by(id: shopify_store_id)
    return unless store

    shop_tz = ActiveSupport::TimeZone[store.timezone] || ActiveSupport::TimeZone["UTC"]
    shop_today = Time.current.in_time_zone(shop_tz).to_date

    service = ShopifyAnalyticsService.new(
      shop_domain: store.shop_domain,
      access_token: store.access_token,
      store_id: store.id,
      timezone: store.timezone
    )

    ((shop_today - days.days)..shop_today).each do |date|
      service.sync_date(date)
    rescue => e
      Rails.logger.error("[BackfillShopifyMetrics] store=#{store.shop_domain} date=#{date}: #{e.message}")
    end
  end
end
