FactoryBot.define do
  factory :group do
    company
    sequence(:name) { |n| "Group #{n}" }
    description { nil }
    position { 0 }
  end
end
