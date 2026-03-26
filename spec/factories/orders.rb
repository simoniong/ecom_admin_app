FactoryBot.define do
  factory :order do
    customer
    sequence(:shopify_order_id) { |n| 5000 + n }
    email { customer.email }
    sequence(:name) { |n| "##{1000 + n}" }
    total_price { 99.99 }
    currency { "USD" }
    financial_status { "paid" }
    fulfillment_status { "fulfilled" }
    ordered_at { 1.day.ago }
    shopify_data { {} }
  end
end
