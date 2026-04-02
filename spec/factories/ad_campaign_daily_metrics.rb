FactoryBot.define do
  factory :ad_campaign_daily_metric do
    ad_campaign
    date { Date.current }
    impressions { 1000 }
    clicks { 50 }
    add_to_cart { 10 }
    checkout_initiated { 5 }
    purchases { 3 }
    spend { 100.00 }
    conversion_value { 300.00 }
  end
end
