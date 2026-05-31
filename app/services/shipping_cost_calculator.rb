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

    rate = version.rates.for_weight(weight_kg).first
    return nil unless rate

    cost_cny = (weight_kg * rate.per_kg_rate_cny) + rate.flat_fee_cny
    (cost_cny / @store.cost_fx_rate).round(2)
  end

  private

  def country_code_from_order
    @order.shopify_data&.dig("shipping_address", "country_code") ||
      @order.shopify_data&.dig("billing_address", "country_code")
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
