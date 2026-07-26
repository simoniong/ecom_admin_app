FactoryBot.define do
  factory :ad_unit do
    ad_account
    ad_creative { association(:ad_creative, ad_account: ad_account) }
    sequence(:ad_id) { |n| "ad_#{100000 + n}" }
    sequence(:ad_name) { |n| "Ad #{n}" }
    sequence(:adset_id) { |n| "adset_#{100000 + n}" }
    status { "active" }
    multi_asset { false }
  end
end
