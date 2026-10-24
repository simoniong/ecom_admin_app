class SyncAllShopifyOrdersRecurringJob < ApplicationJob
  queue_as :default

  def perform
    ShopifyStore.find_each do |store|
      incremental = store.orders_synced_at.present?

      SyncRun.track(source: "shopify_orders", target: store, trigger: "auto") do
        SyncAllOrdersService.new(store).call(incremental: incremental)
      end
    rescue => e
      Rails.logger.error("[SyncAllShopifyOrdersRecurring] store=#{store.shop_domain}: #{e.message}")
    end
  end
end
