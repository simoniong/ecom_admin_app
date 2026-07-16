module ParcelsHelper
  # Regional-indicator flag emoji from a 2-letter ISO country code, e.g.
  # "AU" -> "🇦🇺". Nil-safe: an unrecognized/blank code renders no flag
  # rather than garbage — this is decorative, never load-bearing.
  def parcel_country_flag(code)
    return nil if code.blank? || code.length != 2
    code.upcase.each_char.map { |c| (c.ord + 127397).chr(Encoding::UTF_8) }.join
  end

  # Localized country name. Reuses the existing shipping_rate_cards.countries
  # i18n table (the only place in the app with Chinese country names today)
  # since every country this report can price is one of the 8 codes that
  # table already covers (ShippingRateCardVersion::COUNTRY_CODES) — falls
  # back to the raw code for anything outside that set instead of blowing up.
  def parcel_country_name(code)
    return nil if code.blank?
    t("shipping_rate_cards.countries.#{code}", default: code)
  end

  # The destination country code a Basis was resolved against, purely for
  # display (the "預估依據" line's flag/name chip). Duplicates
  # ShippingCostCalculator's private country-resolution rule (shipping
  # address preferred, billing as fallback) rather than reaching into that
  # service, since this is decorative and must not couple view rendering to
  # a private method on a service we're told not to modify.
  def parcel_order_country_code(order)
    data = order.shopify_data
    return nil unless data
    shipping = data["shipping_address"]
    return shipping["country_code"] if shipping && shipping["country_code"].present?
    data.dig("billing_address", "country_code")
  end

  # A CNY figure formatted to 2dp with a ¥ prefix. nil renders as an em dash
  # so a genuinely-unknown amount never gets rendered as "¥" with nothing
  # after it (or worse, coerced into "¥0.00").
  def cny(value)
    return "—" if value.nil?
    "¥#{number_with_precision(value, precision: 2, delimiter: ',')}"
  end

  # Signed CNY/USD text for use inside i18n interpolations (the recon
  # section's prose, e.g. "why the +¥73.80 (+$10.94) difference?") where a
  # <span>-returning helper like dual_currency can't be used. Nil-safe, and
  # only ever prefixes "+" on a positive value — a negative (a saving, not an
  # overrun) keeps its own "-" from to_s, never gets double-signed.
  def signed_cny(value)
    return "—" if value.nil?
    "#{value.positive? ? "+" : ""}#{cny(value)}"
  end

  def signed_usd(value)
    return "—" if value.nil?
    "#{value.positive? ? "+" : ""}#{number_to_currency(value)}"
  end

  # The report's recurring "CNY primary (bold) / USD secondary (small, grey)"
  # cell — order-row totals, every per-parcel estimate/actual/variance, and
  # the tfoot totals all share this exact shape. `over` reddens both lines
  # (money the operator is losing); `sign` prefixes a "+" on positive values
  # (variance columns only — an estimate or actual total is never signed).
  # A nil cny_value renders as a plain dash with no usd line at all, so an
  # unknown figure never sprouts a stray "$0.00" underneath it.
  def dual_currency(cny_value, usd_value, over: false, sign: false)
    return tag.span("—", class: "text-gray-400") if cny_value.nil?

    prefix = (sign && cny_value.positive?) ? "+" : ""
    main_text = "#{prefix}#{cny(cny_value)}"
    main_class = over ? "block font-semibold text-red-600" : "block font-semibold text-gray-900"

    tag.span(class: "inline-flex flex-col items-end leading-tight") do
      safe_join([
        tag.span(main_text, class: main_class),
        (if usd_value
           sub_text = "#{prefix}#{number_to_currency(usd_value)}"
           tag.span(sub_text, class: over ? "block text-xs text-red-500" : "block text-xs text-gray-400")
         end)
      ].compact)
    end
  end

  # The per-parcel "分區 預估 / 實際" stacked cell. Each side independently
  # falls back to a dash when its zone is blank (unzoned country's estimate
  # side, or a carrier bill that simply doesn't carry a zone) — no special
  # "hide the whole cell for unzoned countries" branch, since dashing each
  # side on its own merits already produces the right look for that case.
  def dual_zone(estimated_zone, billed_zone, mismatch: false)
    est_text = estimated_zone.presence || "—"
    act_text = billed_zone.presence || "—"
    value_class = mismatch ? "font-semibold text-red-600" : (estimated_zone.presence || billed_zone.presence) ? "font-semibold text-amber-600" : "font-semibold text-gray-400"

    tag.span(class: "inline-flex flex-col items-end gap-0.5 text-xs") do
      safe_join([
        tag.span(class: "inline-flex items-center gap-1") { tag.span(t("parcels.est"), class: "text-gray-400") + tag.span(est_text, class: value_class) },
        tag.span(class: "inline-flex items-center gap-1") { tag.span(t("parcels.act"), class: "text-gray-400") + tag.span(act_text, class: value_class) },
        (tag.span(t("parcels.zone_mismatch_badge"), class: "text-[10px] font-semibold text-red-600") if mismatch)
      ].compact)
    end
  end
end
