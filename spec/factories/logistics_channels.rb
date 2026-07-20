FactoryBot.define do
  factory :logistics_channel do
    logistics_account
    sequence(:name) { |n| "Channel #{n}" }
    sequence(:product_id) { |n| "PID#{n}" }
    shopify_carrier_name { "Other" }
    tracking_url_template { "https://t.17track.net/en#nums=#TrackingNumber#" }
  end
end
