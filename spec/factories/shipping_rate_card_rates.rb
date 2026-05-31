FactoryBot.define do
  factory :shipping_rate_card_rate do
    association :version, factory: :shipping_rate_card_version
    weight_min_kg { 0.05 }
    weight_max_kg { 0.2 }
    per_kg_rate_cny { 92.0 }
    flat_fee_cny { 25.0 }
  end
end
