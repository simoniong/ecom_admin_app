class ProcessShopifyOrderWebhookJob < ApplicationJob
  queue_as :default

  def perform(shopify_store_id, order_payload)
    store = ShopifyStore.find_by(id: shopify_store_id)
    return unless store

    SyncAllOrdersService.new(store).sync_single_order(order_payload)
  rescue => e
    Rails.logger.error("[ProcessShopifyOrderWebhook] store_id=#{shopify_store_id} order=#{order_payload['id']}: #{e.message}")
  end
end
