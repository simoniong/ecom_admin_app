FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password123" }
    password_confirmation { "password123" }
    failed_attempts { 0 }

    after(:create) do |user|
      company = create(:company, name: "#{user.email.split('@').first}'s Company")
      create(:membership, user: user, company: company, role: :owner)
    end
  end
end
