FactoryBot.define do
  factory :invitation do
    company
    association :invited_by, factory: :user
    sequence(:email) { |n| "invited#{n}@example.com" }
    role { :member }
    permissions { %w[dashboard orders] }
  end
end
