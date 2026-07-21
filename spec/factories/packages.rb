FactoryBot.define do
  factory :package do
    shopify_store
    order { association(:order, shopify_store: shopify_store) }
    sequence(:number) { |n| n }
    aasm_state { "pending_review" }
    application_status { "none" }
  end
end
