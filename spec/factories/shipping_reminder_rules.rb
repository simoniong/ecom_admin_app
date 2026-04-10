FactoryBot.define do
  factory :shipping_reminder_rule do
    company
    rule_type { "not_delivered" }
    enabled { true }
    country_thresholds { [ { "country" => "US", "days" => 14 } ] }
  end
end
