FactoryBot.define do
  factory :product_variant do
    product
    sequence(:shopify_variant_id) { |n| 8000 + n }
    sequence(:sku) { |n| "SKU-#{n}" }
    title { "Default" }
    price { 29.99 }
    currency { "USD" }
    unit_cost { nil }
    weight_grams { nil }
    packaging_cost { 0 }
    shopify_data { {} }
  end
end
