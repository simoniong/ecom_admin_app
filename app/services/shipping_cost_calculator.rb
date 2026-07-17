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

  # A resolved Basis, or the reason it couldn't be resolved. `reason` is a
  # symbol (see #resolve) when `basis` is nil, and nil when `basis` is present.
  # Callers that only want the Basis use .basis / #basis; diagnostics (e.g. the
  # reestimate rake task explaining which orders it skipped) read `reason`.
  Resolution = Struct.new(:basis, :reason, keyword_init: true)

  def self.estimate(order)
    new(order).call
  end

  def self.resolve(order, cache: {})
    new(order, cache: cache).resolve
  end

  # `cache` is an optional Hash the CALLER owns and reuses across multiple
  # orders in the same request (e.g. the /parcels index, which resolves a
  # Basis for up to 25 orders per page). Left at its default `{}`, a fresh
  # cache is created per call and behaves exactly as before — every existing
  # caller that doesn't know about this parameter is unaffected. Memoizes the
  # two DB round trips that are otherwise repeated once per order despite
  # frequently sharing the same key: the rate-card-version lookup (keyed on
  # company/country/service_type/date) and the postal-zone resolution (keyed
  # on company/country[/postal key]).
  def self.basis(order, cache: {})
    new(order, cache: cache).basis
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

  def initialize(order, cache: {})
    @order = order
    @store = order.shopify_store
    @cache = cache
  end

  def call
    basis&.order_estimate
  end

  # The Basis for this order, or nil when it can't be resolved (see #resolve for
  # the exact guards). Unchanged public contract — every existing caller gets
  # the same Basis-or-nil.
  def basis
    resolve.basis
  end

  # Resolve the order-level pricing context (rate card version, zone, order
  # weight, fx rate), OR the reason it can't be. Same guards, same order, as
  # basis-or-nil always used; the reason symbol just names which guard tripped
  # so callers can report WHY an order has no estimate:
  #   :no_fx_rate      store has no positive cost_fx_rate
  #   :no_service_type store has no default_service_type
  #   :no_order_date   order has no ordered_at
  #   :no_country      no destination country on the order
  #   :no_weight       no line items, or a line item has no positive weight
  #   :no_rate_card    no rate card version covers the order's country/date
  #   :unmatched_zone  zoned country, but the postal matches no zone rule
  def resolve
    return Resolution.new(reason: :no_fx_rate) unless @store&.cost_fx_rate&.positive?
    return Resolution.new(reason: :no_service_type) unless @store.default_service_type.present?
    return Resolution.new(reason: :no_order_date) unless @order.ordered_at

    country = country_code_from_order
    return Resolution.new(reason: :no_country) unless country

    weight_kg = total_weight_kg
    return Resolution.new(reason: :no_weight) unless weight_kg && weight_kg.positive?

    version = fetch_version(country, @order.ordered_at.to_date)
    return Resolution.new(reason: :no_rate_card) unless version

    zone = resolve_zone(country)   # nil = unzoned country, String = matched zone, :unmatched = give up
    return Resolution.new(reason: :unmatched_zone) if zone == :unmatched

    Resolution.new(basis: Basis.new(
      version: version,
      zone: zone,
      zoned: !zone.nil?,
      order_weight_kg: weight_kg,
      fx_rate: @store.cost_fx_rate
    ))
  end

  private

  # Memoized per (company, country, service_type, date) in @cache — repeated
  # for every order on the same store/country/date range, which is the common
  # case on the /parcels report.
  def fetch_version(country, on_date)
    key = [ @store.company_id, country, @store.default_service_type, on_date ]
    cache_slot(:version).fetch(key) do
      cache_slot(:version)[key] = ShippingRateCardVersion.lookup(
        company:      @store.company,
        country:      country,
        service_type: @store.default_service_type,
        on_date:      on_date
      )
    end
  end

  def resolve_zone(country)
    return nil unless zoned_country?(country)
    key = PostalNormalizer.normalize(country, postal_from_order)
    return :unmatched unless key
    fetch_zone_for(country, key) || :unmatched
  end

  # Memoized per (company, country) — every order for the same zoned country
  # asks this identical yes/no question.
  def zoned_country?(country)
    key = [ @store.company_id, country ]
    cache_slot(:zoned).fetch(key) do
      cache_slot(:zoned)[key] = ShippingZonePostalRule.country_zoned?(company: @store.company, country: country)
    end
  end

  # Memoized per (company, country, postal key) — distinct orders frequently
  # share a postal code (or at least a company/country pair), so this still
  # collapses a meaningful share of repeat lookups even though the key is
  # more granular than the version/zoned caches above.
  def fetch_zone_for(country, key)
    cache_key = [ @store.company_id, country, key ]
    cache_slot(:zone_for).fetch(cache_key) do
      cache_slot(:zone_for)[cache_key] = ShippingZonePostalRule.zone_for(company: @store.company, country: country, key: key)
    end
  end

  def cache_slot(name)
    @cache[name] ||= {}
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

  # When the caller has already preloaded order_line_items (and their
  # product_variant) — e.g. via `.includes(order_line_items: :product_variant)`
  # on the /parcels index — reuse that loaded association rather than
  # re-scoping it. Calling `.includes` on an already-loaded CollectionProxy
  # builds a brand-new AR::Relation and ignores the preload, silently
  # re-querying per order; checking `loaded?` first avoids that.
  def total_weight_kg
    association = @order.order_line_items
    items = (association.loaded? ? association : association.includes(:product_variant)).to_a
    return nil if items.empty?
    # If any line lacks a usable (positive) weight, refuse to estimate rather
    # than silently treating it as 0 (which would underestimate the cost).
    return nil unless items.all? { |li| li.product_variant&.weight_grams&.positive? }
    items.sum { |li| li.product_variant.weight_grams * li.quantity } / 1000.0
  end
end
