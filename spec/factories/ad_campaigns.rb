FactoryBot.define do
  factory :ad_campaign do
    ad_account
    sequence(:campaign_id) { |n| "camp_#{100000 + n}" }
    sequence(:campaign_name) { |n| "Campaign #{n}" }
    status { "active" }
    daily_budget { 50.00 }
  end
end
