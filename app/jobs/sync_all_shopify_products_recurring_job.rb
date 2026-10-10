# Keeps every store's product catalogue current. Without it variants only
# arrived on a manual sync, so a product line launched in Shopify had no
# ProductVariant here: its order line items linked to nothing, carried no
# weight or cost, and every order containing one silently lost its shipping
# estimate and COGS.
class SyncAllShopifyProductsRecurringJob < ApplicationJob
  queue_as :default

  def perform
    ShopifyStore.find_each do |store|
      SyncShopifyProductsService.new(store).call
    rescue => e
      Rails.logger.error("[SyncAllShopifyProductsRecurring] store=#{store.shop_domain}: #{e.message}")
    end
  end
end
