FactoryBot.define do
  factory :membership do
    company
    user
    role { :owner }
    permissions { [] }
  end
end
