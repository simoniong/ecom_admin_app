FactoryBot.define do
  factory :shopify_store do
    user
    sequence(:shop_domain) { |n| "test-store-#{n}.myshopify.com" }
    access_token { "shpat_test_token" }
    scopes { "read_products,read_customers,read_orders,read_fulfillments,read_analytics" }
    installed_at { Time.current }
  end
end
