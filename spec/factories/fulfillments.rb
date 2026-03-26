FactoryBot.define do
  factory :fulfillment do
    order
    sequence(:shopify_fulfillment_id) { |n| 9000 + n }
    status { "success" }
    sequence(:tracking_number) { |n| "TRACK#{n}" }
    tracking_company { "USPS" }
    tracking_url { "https://tracking.example.com" }
    tracking_details { {} }
    shopify_data { {} }
  end
end
