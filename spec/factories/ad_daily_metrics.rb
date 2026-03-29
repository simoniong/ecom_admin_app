FactoryBot.define do
  factory :ad_daily_metric do
    ad_account
    date { Date.current }
    spend { 100.50 }
    impressions { 5000 }
    clicks { 150 }
    conversions { 10 }
    conversion_value { 500.00 }
  end
end
