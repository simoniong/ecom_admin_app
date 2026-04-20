class ProcessShopRedactJob < ApplicationJob
  queue_as :default

  def perform(shopify_store_id)
    store = ShopifyStore.find_by(id: shopify_store_id)
    return unless store

    ShopifyStoreDeletionService.new(store).call
  rescue => e
    Rails.logger.error("[ProcessShopRedact] store_id=#{shopify_store_id}: #{e.message}")
  end
end
