FactoryBot.define do
  factory :ad_creative do
    ad_account
    asset_type { "video" }
    sequence(:asset_id) { |n| "video_#{100000 + n}" }
    sequence(:name) { |n| "Creative #{n}" }
    thumbnail_url { "https://example.com/thumb.jpg" }
    duration_seconds { 30 }
    first_spend_date { nil }
  end
end
