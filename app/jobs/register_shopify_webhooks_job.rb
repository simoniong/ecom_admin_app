class RegisterShopifyWebhooksJob < ApplicationJob
  queue_as :default

  def perform(shopify_store_id)
    store = ShopifyStore.find_by(id: shopify_store_id)
    return unless store

    ShopifyWebhookRegistrationService.new(store).call
  rescue => e
    Rails.logger.error("[RegisterShopifyWebhooks] store_id=#{shopify_store_id}: #{e.message}")
  end
end
