FactoryBot.define do
  factory :product_variant do
    product
    sequence(:shopify_variant_id)        { |n| 8000 + n }
    sequence(:shopify_inventory_item_id) { |n| 9000 + n }
    sequence(:sku) { |n| "SKU-#{n}" }
    title { "Default" }
    price { 29.99 }
    currency { "USD" }
    shopify_cost { nil }
    unit_cost { nil }
    shopify_weight_grams { 250 }
    weight_grams { nil }
    shopify_data { {} }
  end
end
