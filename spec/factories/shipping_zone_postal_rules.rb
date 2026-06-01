FactoryBot.define do
  factory :shipping_zone_postal_rule do
    company
    country_code { "AU" }
    zone { "1" }
    postal_start { "2000" }
    postal_end { "2079" }
  end
end
