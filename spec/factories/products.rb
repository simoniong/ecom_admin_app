FactoryBot.define do
  factory :product do
    shopify_store
    sequence(:shopify_product_id) { |n| 7000 + n }
    sequence(:title) { |n| "Paint Kit #{n}" }
    handle { title.parameterize }
    status { "active" }
    image_url { nil }
    shopify_data { {} }
  end
end
