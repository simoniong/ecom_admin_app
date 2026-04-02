class SyncAllShopifyOrdersRecurringJob < ApplicationJob
  queue_as :default

  def perform
    ShopifyStore.find_each do |store|
      incremental = store.orders_synced_at.present?
      SyncAllOrdersService.new(store).call(incremental: incremental)
    rescue => e
      Rails.logger.error("[SyncAllShopifyOrdersRecurring] store=#{store.shop_domain}: #{e.message}")
    end
  end
end
