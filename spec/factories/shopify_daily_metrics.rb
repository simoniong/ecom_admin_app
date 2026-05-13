FactoryBot.define do
  factory :shopify_daily_metric do
    association :shopify_store
    date { Date.current }
    sessions { 500 }
    orders_count { 20 }
    new_customer_orders_count { 5 }
    revenue { 1500.00 }
    conversion_rate { 0.04 }
  end
end
