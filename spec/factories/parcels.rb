FactoryBot.define do
  factory :parcel do
    shopify_store
    order { nil }
    sequence(:identifier) { |n| "XMBDE#{2012380 + n}" }
    sequence(:internal_no) { |n| "DOR#{201415420 + n}CN" }
    sequence(:tracking_number) { |n| "YWSFO#{10040079220 + n}" }
    shipped_at { 3.days.ago }
    service_channel { "美国标准（A带电）" }
    country { "美国" }
    actual_weight_g { 2423 }
    billed_weight_g { 2421 }
    cost_cny { 239.73 }
    freight_cny { 222.73 }
    registration_fee_cny { 15 }
    tax_cny { 0 }
    remote_area_fee_cny { 0 }
    operation_fee_cny { 2 }
    fx_rate_snapshot { 7.2 }
    cost_amount { 33.30 }
  end
end
