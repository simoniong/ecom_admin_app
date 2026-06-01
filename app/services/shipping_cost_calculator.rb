class ShippingCostCalculator
  def self.estimate(order)
    new(order).call
  end

  def initialize(order)
    @order = order
    @store = order.shopify_store
  end

  def call
    return nil unless @store&.cost_fx_rate&.positive?
    return nil unless @store.default_service_type.present?
    return nil unless @order.ordered_at

    country = country_code_from_order
    return nil unless country

    weight_kg = total_weight_kg
    return nil unless weight_kg && weight_kg.positive?

    version = ShippingRateCardVersion.lookup(
      company:      @store.company,
      country:      country,
      service_type: @store.default_service_type,
      on_date:      @order.ordered_at.to_date
    )
    return nil unless version

    zone = resolve_zone(country)   # nil = unzoned country, String = matched zone, :unmatched = give up
    return nil if zone == :unmatched

    bands = version.rates.where(zone: zone).to_a
    cost_cny = cost_cny_for(bands, weight_kg)
    return nil unless cost_cny

    (cost_cny / @store.cost_fx_rate).round(2)
  end

  private

  def resolve_zone(country)
    return nil unless ShippingZonePostalRule.country_zoned?(company: @store.company, country: country)
    key = PostalNormalizer.normalize(country, postal_from_order)
    return :unmatched unless key
    ShippingZonePostalRule.zone_for(company: @store.company, country: country, key: key) || :unmatched
  end

  def postal_from_order
    destination_address&.dig("zip")
  end

  def country_code_from_order
    destination_address&.dig("country_code")
  end

  # Resolve country AND postal from the SAME address: prefer shipping (when it
  # carries a country), else billing — so a zoned country never matches a
  # billing postal against a shipping country.
  def destination_address
    data = @order.shopify_data
    return nil unless data
    shipping = data["shipping_address"]
    return shipping if shipping && shipping["country_code"].present?
    data["billing_address"]
  end

  def total_weight_kg
    items = @order.order_line_items.includes(:product_variant).to_a
    return nil if items.empty?
    # If any line lacks a usable (positive) weight, refuse to estimate rather
    # than silently treating it as 0 (which would underestimate the cost).
    return nil unless items.all? { |li| li.product_variant&.weight_grams&.positive? }
    items.sum { |li| li.product_variant.weight_grams * li.quantity } / 1000.0
  end

  # Cost in CNY for a weight against a set of bands. If the weight exceeds the
  # heaviest band, simulate a greedy split into parcels at the max band weight,
  # charging each parcel its own per-kg charge + handling fee. Returns nil if any
  # parcel's weight matches no band.
  def cost_cny_for(bands, weight_kg)
    band = band_for(bands, weight_kg)
    return parcel_cost(band, weight_kg) if band

    max = bands.map(&:weight_max_kg).max
    return nil unless max && weight_kg > max

    total = BigDecimal("0")
    remaining = weight_kg
    while remaining > max
      full = band_for(bands, max)
      return nil unless full

      total += parcel_cost(full, max)
      remaining -= max
    end
    if remaining > 0
      rem = band_for(bands, remaining)
      return nil unless rem

      total += parcel_cost(rem, remaining)
    end
    total
  end

  def band_for(bands, weight_kg)
    bands.find { |b| b.weight_min_kg < weight_kg && b.weight_max_kg >= weight_kg }
  end

  def parcel_cost(band, weight_kg)
    (weight_kg * band.per_kg_rate_cny) + band.flat_fee_cny
  end
end
