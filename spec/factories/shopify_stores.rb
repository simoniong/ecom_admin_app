FactoryBot.define do
  factory :shopify_store do
    user
    company { user&.companies&.first || association(:company) }
    sequence(:shop_domain) { |n| "test-store-#{n}.myshopify.com" }
    access_token { "shpat_test_token" }
    scopes { "read_products,read_customers,read_all_orders,read_fulfillments,read_analytics" }
    installed_at { Time.current }
  end
end
