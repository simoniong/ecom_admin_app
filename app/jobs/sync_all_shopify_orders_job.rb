class SyncAllShopifyOrdersJob < ApplicationJob
  queue_as :default

  def perform(shopify_store_id, full: false, trigger: "manual", sync_batch_id: nil)
    store = ShopifyStore.find_by(id: shopify_store_id)
    return unless store

    incremental = !full && store.orders_synced_at.present?
    SyncRun.track(source: "shopify_orders", target: store, trigger: trigger, batch_id: sync_batch_id) do
      SyncAllOrdersService.new(store).call(incremental: incremental)
    end
  rescue => e
    Rails.logger.error("[SyncAllShopifyOrdersJob] store_id=#{shopify_store_id}: #{e.message}")
  end
end
