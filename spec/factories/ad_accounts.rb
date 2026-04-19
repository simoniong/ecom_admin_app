FactoryBot.define do
  factory :ad_account do
    user
    company { user&.companies&.first || association(:company) }
    platform { "meta" }
    sequence(:account_id) { |n| "act_#{100000 + n}" }
    sequence(:account_name) { |n| "Ad Account #{n}" }
    access_token { "test-meta-access-token" }
    token_expires_at { 60.days.from_now }

    trait :with_group do
      after(:build) do |account|
        account.group ||= create(:group, company: account.company)
      end
    end
  end
end
