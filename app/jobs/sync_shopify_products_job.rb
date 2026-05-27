class SyncShopifyProductsJob < ApplicationJob
  queue_as :default

  def perform(shopify_store_id)
    store = ShopifyStore.find(shopify_store_id)
    SyncShopifyProductsService.new(store).call
  end
end
