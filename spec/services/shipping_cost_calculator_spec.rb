require "rails_helper"

RSpec.describe ShippingCostCalculator do
  let(:company) { create(:company) }
  let(:user) { create(:user) }
  let(:store) do
    create(:shopify_store, user: user, company: company,
           currency: "USD", cost_fx_rate: 7.0, default_service_type: "with_battery")
  end
  let(:customer) { create(:customer, shopify_store: store) }

  # 0.3 kg US order with one weighted variant.
  def build_order(weight_grams: 300, country: "US", ordered_on: Date.new(2026, 4, 15))
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: store.active_timezone.local(ordered_on.year, ordered_on.month, ordered_on.day, 12),
                   shopify_data: { "shipping_address" => { "country_code" => country } })
    product = create(:product, shopify_store: store)
    variant = create(:product_variant, product: product, weight_grams: weight_grams)
    create(:order_line_item, order: order, product_variant: variant, quantity: 1)
    order
  end

  def build_version_with_band(country: "US", service: "with_battery",
                              from: Date.new(2026, 1, 1), to: nil,
                              min: 0.201, max: 0.45, per_kg: 92.0, flat: 23.0, name: "V")
    version = create(:shipping_rate_card_version, company: company, name: name,
                     country_code: country, service_type: service, effective_from: from, effective_to: to)
    create(:shipping_rate_card_rate, version: version,
           weight_min_kg: min, weight_max_kg: max, per_kg_rate_cny: per_kg, flat_fee_cny: flat)
    version
  end

  it "returns the band cost converted to store currency" do
    build_version_with_band
    order = build_order(weight_grams: 300) # 0.3 kg → band 0.201..0.45
    # cny = 0.3 * 92 + 23 = 50.6; usd = 50.6 / 7.0 = 7.23
    expect(ShippingCostCalculator.estimate(order)).to eq(7.23)
  end

  it "uses the older version for an early date and the newer one once it takes over" do
    build_version_with_band(name: "old", from: Date.new(2026, 1, 1), per_kg: 92.0, flat: 23.0)
    build_version_with_band(name: "new", from: Date.new(2026, 5, 1), per_kg: 100.0, flat: 30.0)

    early = build_order(weight_grams: 300, ordered_on: Date.new(2026, 4, 15))
    late  = build_order(weight_grams: 300, ordered_on: Date.new(2026, 5, 10))

    expect(ShippingCostCalculator.estimate(early)).to eq((((0.3 * 92.0) + 23.0) / 7.0).round(2))
    expect(ShippingCostCalculator.estimate(late)).to eq((((0.3 * 100.0) + 30.0) / 7.0).round(2))
  end

  it "returns nil when the variant has no weight" do
    build_version_with_band
    order = build_order(weight_grams: nil)
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when ANY line item lacks a weight (avoids underestimating)" do
    build_version_with_band
    order = build_order(weight_grams: 300) # first line has weight
    weightless_variant = create(:product_variant, product: create(:product, shopify_store: store), weight_grams: nil)
    create(:order_line_item, order: order, product_variant: weightless_variant, quantity: 1)
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when the order has no ordered_at" do
    build_version_with_band
    order = build_order(weight_grams: 300)
    order.update_column(:ordered_at, nil)
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "falls back to billing_address country when shipping_address is missing" do
    build_version_with_band(country: "US")
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                   shopify_data: { "billing_address" => { "country_code" => "US" } })
    product = create(:product, shopify_store: store)
    variant = create(:product_variant, product: product, weight_grams: 300)
    create(:order_line_item, order: order, product_variant: variant, quantity: 1)
    expect(ShippingCostCalculator.estimate(order)).to eq(7.23)
  end

  it "returns nil when no country can be determined" do
    build_version_with_band
    order = create(:order, customer: customer, shopify_store: store, shopify_data: {})
    product = create(:product, shopify_store: store)
    variant = create(:product_variant, product: product, weight_grams: 300)
    create(:order_line_item, order: order, product_variant: variant, quantity: 1)
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when no version covers the date" do
    build_version_with_band(from: Date.new(2026, 6, 1))
    order = build_order(ordered_on: Date.new(2026, 1, 1))
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when no weight band matches" do
    build_version_with_band(min: 1.0, max: 2.0)
    order = build_order(weight_grams: 300)
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when the store has no default_service_type" do
    build_version_with_band
    store.update!(default_service_type: nil)
    order = build_order
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  it "returns nil when the store has no cost_fx_rate" do
    build_version_with_band
    store.update!(cost_fx_rate: nil)
    order = build_order
    expect(ShippingCostCalculator.estimate(order)).to be_nil
  end

  describe "zone-based countries" do
    def au_order(zip:, ordered_on: Date.new(2026, 4, 15))
      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(ordered_on.year, ordered_on.month, ordered_on.day, 12),
                     shopify_data: { "shipping_address" => { "country_code" => "AU", "zip" => zip } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 300)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      order
    end

    before do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1", postal_start: "2000", postal_end: "2079")
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "2", postal_start: "2080", postal_end: "2084")
      version = create(:shipping_rate_card_version, company: company, country_code: "AU",
                       service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: version, zone: "1", weight_min_kg: 0.201, weight_max_kg: 0.45, per_kg_rate_cny: 92.0, flat_fee_cny: 23.0)
      create(:shipping_rate_card_rate, version: version, zone: "2", weight_min_kg: 0.201, weight_max_kg: 0.45, per_kg_rate_cny: 100.0, flat_fee_cny: 30.0)
    end

    it "uses the zone-1 rate for a zone-1 postcode" do
      expect(ShippingCostCalculator.estimate(au_order(zip: "2075"))).to eq(7.23)
    end

    it "uses the zone-2 rate for a zone-2 postcode" do
      expect(ShippingCostCalculator.estimate(au_order(zip: "2082"))).to eq(8.57)
    end

    it "returns nil when the postcode matches no zone" do
      expect(ShippingCostCalculator.estimate(au_order(zip: "9999"))).to be_nil
    end

    it "returns nil when the order has no postcode" do
      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     shopify_data: { "shipping_address" => { "country_code" => "AU" } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 300)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      expect(ShippingCostCalculator.estimate(order)).to be_nil
    end

    it "returns nil when the version has no rate for the resolved zone" do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "3", postal_start: "3000", postal_end: "3062")
      expect(ShippingCostCalculator.estimate(au_order(zip: "3050"))).to be_nil
    end

    it "does not match a billing postcode against the shipping country" do
      # shipping has the country but no zip; billing has a zone-1 zip.
      # country+postal must come from the same address, so this is uncovered.
      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     shopify_data: {
                       "shipping_address" => { "country_code" => "AU" },
                       "billing_address" => { "country_code" => "AU", "zip" => "2075" }
                     })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 300)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      expect(ShippingCostCalculator.estimate(order)).to be_nil
    end
  end
end
