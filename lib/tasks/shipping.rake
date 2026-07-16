namespace :shipping do
  desc "Recompute frozen estimated_shipping_cost with current rate cards. ENV: COUNTRY (blank=all), FROM (ISO date, blank=all dates), STORE (store id, blank=all)"
  task reestimate: :environment do
    from = ENV["FROM"].present? ? Date.parse(ENV["FROM"]) : nil
    store_ids = ENV["STORE"].present? ? [ ENV["STORE"] ] : nil
    r = ReestimateShippingCostsService.new(country: ENV["COUNTRY"].presence, from: from, store_ids: store_ids).call
    puts "shipping:reestimate scanned=#{r[:scanned]} updated=#{r[:updated]} skipped=#{r[:skipped]}"
  end
end
