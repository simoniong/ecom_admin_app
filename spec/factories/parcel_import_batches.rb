FactoryBot.define do
  factory :parcel_import_batch do
    shopify_store
    user
    filename { "2026.6月SIMON.xlsx" }
    rows { [] }
    row_count { 0 }
    total_cny { 0 }
    status { "pending" }
  end
end
