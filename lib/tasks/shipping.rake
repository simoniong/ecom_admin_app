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
  end
end
