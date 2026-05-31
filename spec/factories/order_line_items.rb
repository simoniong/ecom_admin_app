FactoryBot.define do
  factory :order_line_item do
    order
    product_variant { nil }
    sequence(:shopify_line_item_id) { |n| 6000 + n }
    sequence(:sku_at_sale) { |n| "SOLD-#{n}" }
    title_at_sale { "Sample Item" }
    quantity { 1 }
    unit_price { 29.99 }
    unit_cost_snapshot { nil }
    currency { "USD" }
    shopify_data { {} }
  end
end
