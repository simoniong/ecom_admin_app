namespace :shopify do
  desc "Backfill new_customer_orders_count by re-running ShopifyAnalyticsService#sync_date for the past N days (default 90)"
  task :backfill_new_customer_orders, [ :days ] => :environment do |_, args|
    days = (args[:days] || "90").to_i
    window = (Date.current - (days - 1).days)..Date.current

    ShopifyStore.find_each do |store|
      service = ShopifyAnalyticsService.new(
        shop_domain: store.shop_domain,
        access_token: store.access_token,
        store_id: store.id,
        timezone: store.try(:timezone) || "UTC"
      )

      window.each do |date|
        begin
          service.sync_date(date)
          Rails.logger.info("[backfill] store=#{store.shop_domain} date=#{date} ok")
        rescue => e
          Rails.logger.error("[backfill] store=#{store.shop_domain} date=#{date} error=#{e.message}")
        end
      end
    end
  end
end
