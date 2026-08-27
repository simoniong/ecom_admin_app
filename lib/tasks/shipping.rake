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

  desc "Repair estimates frozen against only part of an order (post-purchase upsell). Reports only unless APPLY=1. ENV: APPLY, FROM (ISO date), STORE (store id)"
  task repair_partial_estimates: :environment do
    from =
      if ENV["FROM"].present?
        begin
          Date.iso8601(ENV["FROM"])
        rescue ArgumentError
          abort "shipping:repair_partial_estimates: FROM must be an ISO date (YYYY-MM-DD), got #{ENV['FROM'].inspect}"
        end
      end
    store_ids = ENV["STORE"].present? ? [ ENV["STORE"] ] : nil
    apply = ENV["APPLY"] == "1"

    r = RepairPartialShippingEstimatesService.new(apply: apply, store_ids: store_ids, from: from).call

    puts apply ? "APPLIED — estimates were written" : "DRY RUN — nothing written (re-run with APPLY=1 to write)"
    puts "scanned=#{r[:scanned]} repairable=#{r[:repairs].size} unexplained=#{r[:unexplained].size}"

    if r[:repairs].any?
      puts
      puts "Repairable (frozen value proven to price only part of the order):"
      r[:repairs].each do |x|
        puts format("  %-12s %8s -> %8s   proven by %d/%d items (%.3f kg of %.3f kg)",
                    x.order_name, x.frozen.to_s, x.repaired.to_s,
                    x.proven_item_count, x.total_item_count,
                    x.proven_weight_kg, x.full_weight_kg)
      end
    end

    if r[:unexplained].any?
      puts
      puts "Unexplained — NOT touched, no subset of the line items reproduces the frozen value."
      puts "These diverge for some other reason (SKU weight, rate card or fx moved). Review by hand:"
      r[:unexplained].each do |x|
        puts format("  %-12s frozen=%-8s recomputed=%-8s", x.order_name, x.frozen.to_s, x.recomputed.to_s)
      end
    end
  end
end
