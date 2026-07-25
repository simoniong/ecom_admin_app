FactoryBot.define do
  factory :ad_unit_daily_metric do
    ad_unit
    date { Date.current }
    spend { 100.00 }
    impressions { 10_000 }
    clicks { 300 }
    inline_link_clicks { 200 }
    video_3_sec_watched { 3_000 }
    video_p25_watched { 2_000 }
    video_p50_watched { 1_200 }
    video_p75_watched { 700 }
    video_p95_watched { 400 }
    video_p100_watched { 300 }
    add_to_cart { 20 }
    checkout_initiated { 10 }
    purchases { 5 }
    conversion_value { 400.00 }
  end
end
