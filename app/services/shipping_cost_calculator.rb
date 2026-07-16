class ShippingCostCalculator
  # A resolved order-level pricing context: the rate card version, zone, order
  # weight and fx rate an order's estimate was (or would be) computed against.
  # Reused to price a parcel's billed weight in the SAME zone/version, so
  # per-parcel estimates stay consistent with the order-level one.
  class Basis
    attr_reader :version, :zone, :zoned, :order_weight_kg, :fx_rate, :rates

    def initialize(version:, zone:, zoned:, order_weight_kg:, fx_rate:)
      @version = version
      @zone = zone
      @zoned = zoned
      @order_weight_kg = order_weight_kg
      @fx_rate = fx_rate
      @rates = version.rates.where(zone: zone)
    end

    # CNY cost for an arbitrary weight, priced against this basis's zone. nil
    # when the weight is missing/non-positive or matches no band (incl. the
    # over-max greedy-split case bottoming out on an unmatched remainder).
    def estimate_cny_for(weight_kg)
      return nil unless weight_kg && weight_kg.positive?
      ShippingCostCalculator.cost_cny_for(rates, weight_kg)
    end

    def order_estimate_cny
      return @order_estimate_cny if defined?(@order_estimate_cny)
      @order_estimate_cny = estimate_cny_for(order_weight_kg)
    end

    def order_estimate
      cny = order_estimate_cny
      return nil unless cny
      (cny / fx_rate).round(2)
    end

    # The rate band used to price the order weight, for the UI's "estimate
    # basis" line (per_kg_rate_cny / flat_fee_cny / weight_min_kg /
    # weight_max_kg). For an order that split over the heaviest band, this is
    # the band at the max weight (the band the split simulation repeats) —
    # not any of the individual split parcels' bands — since that's the
    # single band that best characterizes "the rate card in effect" here.
    def display_band
      return nil unless order_weight_kg && order_weight_kg.positive?
      weight = BigDecimal(order_weight_kg.to_s)

      band = rates.for_weight(weight).first
      return band if band

      bands = rates.to_a
      max = bands.map(&:weight_max_kg).max
      return nil unless max && weight > max
      ShippingCostCalculator.band_for(bands, max)
    end
  end

  def self.estimate(order)
    new(order).call
  end

  def self.basis(order)
    new(order).basis
  end

  # Cost in CNY for a weight against a set of bands. If the weight exceeds the
  # heaviest band, simulate a greedy split into parcels at the max band weight,
  # charging each parcel its own per-kg charge + handling fee. Returns nil if any
  # parcel's weight matches no band.
  def self.cost_cny_for(scope, weight_kg)
    weight = BigDecimal(weight_kg.to_s)   # exact decimal; keeps the money math in BigDecimal

    # Common case: a single band covers the weight — one indexed query, no over-fetch.
    rate = scope.for_weight(weight).first
    return parcel_cost(rate, weight) if rate

    # Over-max: load the bands once and simulate a greedy parcel split.
    bands = scope.to_a
    max = bands.map(&:weight_max_kg).max
    return nil unless max && weight > max

    full_band = band_for(bands, max)
    return nil unless full_band

    # O(1) greedy split: N full parcels at `max` + one remainder parcel.
    full_count = (weight / max).floor
    remainder  = weight - (full_count * max)

    cost = parcel_cost(full_band, max) * full_count
    if remainder.positive?
      rem_band = band_for(bands, remainder)
      return nil unless rem_band

      cost += parcel_cost(rem_band, remainder)
    end
    cost
  end

  def self.band_for(bands, weight_kg)
    bands.find { |b| b.weight_min_kg < weight_kg && b.weight_max_kg >= weight_kg }
  end

  def self.parcel_cost(band, weight_kg)
    (weight_kg * band.per_kg_rate_cny) + band.flat_fee_cny
  end

  def initialize(order)
    @order = order
    @store = order.shopify_store
  end

  def call
    basis&.order_estimate
  end

  # Resolve the order-level pricing context: rate card version, zone, order
  # weight and fx rate. Returns nil under the exact same guards `call` used to
  # apply directly (missing fx rate / service type / country / weight /
  # version / unmatched zone) — nil here means "can't estimate", same as
  # `call` returning nil.
  def basis
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

    Basis.new(
      version: version,
      zone: zone,
      zoned: !zone.nil?,
      order_weight_kg: weight_kg,
      fx_rate: @store.cost_fx_rate
    )
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
end
