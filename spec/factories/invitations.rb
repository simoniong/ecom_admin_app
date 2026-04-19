FactoryBot.define do
  factory :invitation do
    company
    association :invited_by, factory: :user
    sequence(:email) { |n| "invited#{n}@example.com" }
    role { :member }
    permissions { %w[dashboard orders] }

    trait :for_group do
      after(:build) do |invitation|
        invitation.group ||= create(:group, company: invitation.company)
      end
    end
  end
end
