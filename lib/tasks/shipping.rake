namespace :shipping do
  desc "Recompute frozen estimated_shipping_cost with current rate cards. ENV: COUNTRY (blank=all), FROM (ISO date, blank=all dates), STORE (store id, blank=all)"
  task reestimate: :environment do
    from =
      if ENV["FROM"].present?
        begin
          Date.iso8601(ENV["FROM"])
        rescue ArgumentError
          abort "shipping:reestimate: FROM must be an ISO date (YYYY-MM-DD), got #{ENV['FROM'].inspect}"
        end
      end
    store_ids = ENV["STORE"].present? ? [ ENV["STORE"] ] : nil
    r = ReestimateShippingCostsService.new(country: ENV["COUNTRY"].presence, from: from, store_ids: store_ids).call
    puts "shipping:reestimate scanned=#{r[:scanned]} updated=#{r[:updated]} skipped=#{r[:skipped]}"

    reasons = {
      no_fx_rate: "store has no fx rate",
      no_service_type: "store has no default service type",
      no_order_date: "order has no ordered_at",
      no_country: "no destination country",
      no_weight: "missing product weight",
      no_rate_card: "no rate card for the order date",
      unmatched_zone: "postal zone not matched",
      no_matching_band: "weight outside all rate bands"
    }
    r[:skipped_details].each do |d|
      puts "  skipped #{d[:order_name] || d[:order_id]} [#{d[:country] || '?'}] — #{reasons[d[:reason]] || d[:reason]}"
    end
  end
end
