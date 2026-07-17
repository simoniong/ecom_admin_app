FactoryBot.define do
  factory :shipping_remote_area_rule do
    association :version, factory: :shipping_remote_area_version
    postal_start { "IV00" }
    postal_end { "IV99" }
    surcharge_cny { 17 }
    area_label { "area 2" }
  end
end
