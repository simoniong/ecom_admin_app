namespace :shopify do
  desc "Register order webhooks for all Shopify stores with write_webhooks scope"
  task register_webhooks: :environment do
    ShopifyStore.where("scopes LIKE ?", "%write_webhooks%").find_each do |store|
      ShopifyWebhookRegistrationService.new(store).call
      puts "Registered webhooks for #{store.shop_domain}"
    rescue => e
      puts "Failed for #{store.shop_domain}: #{e.message}"
    end
  end
end
