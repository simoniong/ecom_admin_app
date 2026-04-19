FactoryBot.define do
  factory :membership do
    company
    user
    role { :owner }
    permissions { [] }

    trait :member_with_group do
      role { :member }
      after(:build) do |membership|
        membership.group ||= create(:group, company: membership.company)
      end
    end
  end
end
