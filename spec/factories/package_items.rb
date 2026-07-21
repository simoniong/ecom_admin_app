FactoryBot.define do
  factory :package_item do
    package
    sku { "SKU-1" }
    title { "Test item" }
    quantity { 1 }
  end
end
