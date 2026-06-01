FactoryBot.define do
  factory :shipping_rate_card_version do
    company
    sequence(:name) { |n| "Rate Version #{n}" }
    country_code { "US" }
    service_type { "with_battery" }
    effective_from { Date.new(2026, 1, 1) }
    effective_to { nil }
  end
end
