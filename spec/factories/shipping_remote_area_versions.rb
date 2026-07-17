FactoryBot.define do
  factory :shipping_remote_area_version do
    company
    sequence(:name) { |n| "Remote Area v#{n}" }
    country_code { "GB" }
    effective_from { Date.new(2026, 1, 1) }
    effective_to { nil }
  end
end
