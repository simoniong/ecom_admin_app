FactoryBot.define do
  factory :customer do
    shopify_store
    sequence(:shopify_customer_id) { |n| 1000 + n }
    sequence(:email) { |n| "customer#{n}@example.com" }
    first_name { "John" }
    last_name { "Doe" }
    phone { "+1234567890" }
    shopify_data { {} }
  end
end
