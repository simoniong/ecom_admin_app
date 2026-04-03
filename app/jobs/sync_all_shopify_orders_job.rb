class SyncAllShopifyOrdersJob < ApplicationJob
  queue_as :default

  def perform(shopify_store_id, full: false)
    store = ShopifyStore.find_by(id: shopify_store_id)
    return unless store

    incremental = !full && store.orders_synced_at.present?
    SyncAllOrdersService.new(store).call(incremental: incremental)
  rescue => e
    Rails.logger.error("[SyncAllShopifyOrdersJob] store_id=#{shopify_store_id}: #{e.message}")
  end
end
