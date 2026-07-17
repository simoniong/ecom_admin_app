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
    # cny = 0.3 * 92 + 23 + 2 = 52.6; usd = 52.6 / 7.0 = 7.51
    expect(ShippingCostCalculator.estimate(order)).to eq(7.51)
  end

  it "uses the older version for an early date and the newer one once it takes over" do
    build_version_with_band(name: "old", from: Date.new(2026, 1, 1), per_kg: 92.0, flat: 23.0)
    build_version_with_band(name: "new", from: Date.new(2026, 5, 1), per_kg: 100.0, flat: 30.0)

    early = build_order(weight_grams: 300, ordered_on: Date.new(2026, 4, 15))
    late  = build_order(weight_grams: 300, ordered_on: Date.new(2026, 5, 10))

    expect(ShippingCostCalculator.estimate(early)).to eq((((0.3 * 92.0) + 23.0 + 2) / 7.0).round(2))
    expect(ShippingCostCalculator.estimate(late)).to eq((((0.3 * 100.0) + 30.0 + 2) / 7.0).round(2))
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
    expect(ShippingCostCalculator.estimate(order)).to eq(7.51)
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
      expect(ShippingCostCalculator.estimate(au_order(zip: "2075"))).to eq(7.51)
    end

    it "uses the zone-2 rate for a zone-2 postcode" do
      expect(ShippingCostCalculator.estimate(au_order(zip: "2082"))).to eq(8.86)
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

  describe "over-max orders split into parcels" do
    let(:version) do
      create(:shipping_rate_card_version, company: company, country_code: "US",
             service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
    end

    before do
      create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 0, weight_max_kg: 1, per_kg_rate_cny: 27, flat_fee_cny: 23)
      create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 1, weight_max_kg: 5, per_kg_rate_cny: 30, flat_fee_cny: 25)
    end

    def us_order(grams:)
      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     shopify_data: { "shipping_address" => { "country_code" => "US" } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: grams)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      order
    end

    it "splits into 5kg + 0.5kg parcels, each with its own handling fee, using each parcel's band" do
      # 5kg → band 1–5: 5*30+25+2 = 177 ; 0.5kg → band 0–1: 0.5*27+23+2 = 38.5 ; sum 215.5 / 7.0 = 30.79
      expect(ShippingCostCalculator.estimate(us_order(grams: 5500))).to eq(30.79)
    end

    it "handles an exact multiple of the max (10kg → 5 + 5)" do
      # 2 × (5*30+25+2 = 177) = 354 / 7.0 = 50.57
      expect(ShippingCostCalculator.estimate(us_order(grams: 10_000))).to eq(50.57)
    end

    it "splits into three parcels (12kg → 5 + 5 + 2)" do
      # 177 + 177 + (2*30+25+2 = 87) = 441 / 7.0 = 63.0
      expect(ShippingCostCalculator.estimate(us_order(grams: 12_000))).to eq(63.0)
    end

    it "does not split an order at exactly the max (5kg → single parcel)" do
      # band 1–5: 5*30+25+2 = 177 / 7.0 = 25.29
      expect(ShippingCostCalculator.estimate(us_order(grams: 5000))).to eq(25.29)
    end

    it "computes a many-parcel split with a tiny max band in O(1)" do
      # A small top band (max 0.05kg) over a 0.2kg order = 4 parcels — must not loop per-parcel.
      version.rates.delete_all
      create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 0, weight_max_kg: 0.05, per_kg_rate_cny: 100, flat_fee_cny: 5)
      # 4 × (0.05*100 + 5 + 2 = 12) = 48 / 7.0 = 6.86 (6.857… rounds to 6.86)
      expect(ShippingCostCalculator.estimate(us_order(grams: 200))).to eq(6.86)
    end

    it "returns nil when a remainder parcel matches no band (below the lowest min)" do
      version.rates.delete_all
      create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 0.5, weight_max_kg: 1, per_kg_rate_cny: 27, flat_fee_cny: 23)
      create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 1, weight_max_kg: 5, per_kg_rate_cny: 30, flat_fee_cny: 25)
      # 5.4kg → 5kg parcel (band 1–5) + 0.4kg remainder → no band (lowest min 0.5) → nil
      expect(ShippingCostCalculator.estimate(us_order(grams: 5400))).to be_nil
    end

    it "splits a zoned (AU) over-max order using that zone's bands" do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1", postal_start: "2000", postal_end: "2079")
      au_version = create(:shipping_rate_card_version, company: company, country_code: "AU",
                          service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: au_version, zone: "1", weight_min_kg: 0, weight_max_kg: 1, per_kg_rate_cny: 27, flat_fee_cny: 23)
      create(:shipping_rate_card_rate, version: au_version, zone: "1", weight_min_kg: 1, weight_max_kg: 5, per_kg_rate_cny: 30, flat_fee_cny: 25)

      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     shopify_data: { "shipping_address" => { "country_code" => "AU", "zip" => "2075" } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 5500)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      expect(ShippingCostCalculator.estimate(order)).to eq(30.79)
    end
  end

  describe ".basis" do
    it "exposes the resolved version/zone/weight/fx-rate and prices arbitrary weights in that zone" do
      build_version_with_band
      order = build_order(weight_grams: 300)

      basis = ShippingCostCalculator.basis(order)

      expect(basis.zone).to be_nil
      expect(basis.zoned).to be false
      expect(basis.order_weight_kg).to eq(0.3)
      expect(basis.fx_rate).to eq(7.0)
      expect(basis.order_estimate_cny).to eq(52.6)   # 0.3 * 92 + 23 + 2
      expect(basis.order_estimate).to eq(7.51)
      expect(basis.order_estimate).to eq(ShippingCostCalculator.estimate(order))

      # An arbitrary (parcel) weight in the same band, same zone/version.
      expect(basis.estimate_cny_for(0.25)).to eq((0.25 * 92.0) + 23.0 + 2)
      # A weight outside every band returns nil rather than a wrong number.
      expect(basis.estimate_cny_for(10)).to be_nil
      expect(basis.estimate_cny_for(nil)).to be_nil
      expect(basis.estimate_cny_for(0)).to be_nil
    end

    it "exposes the zone and per-zone rates for a zoned country" do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1", postal_start: "2000", postal_end: "2079")
      version = create(:shipping_rate_card_version, company: company, country_code: "AU",
                       service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: version, zone: "1", weight_min_kg: 0.201, weight_max_kg: 0.45, per_kg_rate_cny: 92.0, flat_fee_cny: 23.0)

      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     shopify_data: { "shipping_address" => { "country_code" => "AU", "zip" => "2075" } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 300)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)

      basis = ShippingCostCalculator.basis(order)
      expect(basis.zone).to eq("1")
      expect(basis.zoned).to be true
      expect(basis.rates.to_a).to eq(version.rates.where(zone: "1").to_a)
    end

    it "returns nil under the same guards as .estimate" do
      build_version_with_band
      order = build_order(weight_grams: nil)
      expect(ShippingCostCalculator.basis(order)).to be_nil
    end

    describe "#display_band" do
      it "returns the band that priced the order weight" do
        build_version_with_band(min: 0.201, max: 0.45, per_kg: 92.0, flat: 23.0)
        order = build_order(weight_grams: 300)
        band = ShippingCostCalculator.basis(order).display_band
        expect(band.per_kg_rate_cny).to eq(92.0)
        expect(band.flat_fee_cny).to eq(23.0)
        expect(band.weight_min_kg).to eq(0.201)
        expect(band.weight_max_kg).to eq(0.45)
      end

      it "returns the max band for an over-max (split) order weight" do
        version = create(:shipping_rate_card_version, company: company, country_code: "US",
                         service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
        create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 0, weight_max_kg: 1, per_kg_rate_cny: 27, flat_fee_cny: 23)
        create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: 1, weight_max_kg: 5, per_kg_rate_cny: 30, flat_fee_cny: 25)
        order = build_order(weight_grams: 5500)

        band = ShippingCostCalculator.basis(order).display_band
        expect(band.weight_min_kg).to eq(1)
        expect(band.weight_max_kg).to eq(5)
      end
    end
  end

  describe "remote-area surcharge" do
    let(:company) { create(:company) }
    let(:store) do
      create(:shopify_store, company: company, user: create(:user),
             currency: "USD", cost_fx_rate: 7.0, default_service_type: "with_battery")
    end
    let(:customer) { create(:customer, shopify_store: store) }

    def gb_order(zip:, grams: 1000)
      o = create(:order, customer: customer, shopify_store: store,
                 ordered_at: Time.utc(2026, 6, 15, 12),
                 shopify_data: { "shipping_address" => { "country_code" => "GB", "zip" => zip } })
      variant = create(:product_variant, product: create(:product, shopify_store: store), weight_grams: grams)
      create(:order_line_item, order: o, product_variant: variant, quantity: 1)
      o
    end

    before do
      v = create(:shipping_rate_card_version, company: company, country_code: "GB",
                 service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: v, zone: nil, weight_min_kg: 0, weight_max_kg: 5,
             per_kg_rate_cny: 50, flat_fee_cny: 30) # base 1kg: 50*1+30 = 80 (+¥2 op = 82)

      rav = create(:shipping_remote_area_version, company: company, country_code: "GB",
                   effective_from: Date.new(2026, 6, 1))
      create(:shipping_remote_area_rule, version: rav, postal_start: "IV00", postal_end: "IV99",
             surcharge_cny: 17, area_label: "area 2")
    end

    it "adds the surcharge (per parcel) to a matching postcode's estimate" do
      basis = ShippingCostCalculator.basis(gb_order(zip: "IV1 1AA"))
      # 50*1 + 30 flat + 2 op + 17 remote = 99
      expect(basis.order_estimate_cny).to eq(99)
      expect(basis.remote_surcharge_cny).to eq(17)
      expect(basis.remote_area_label).to eq("area 2")
    end

    it "adds nothing for a non-remote postcode" do
      basis = ShippingCostCalculator.basis(gb_order(zip: "M1 1AA"))
      expect(basis.order_estimate_cny).to eq(82) # 80 base + 2 op, no remote
      expect(basis.remote_surcharge_cny).to eq(0)
    end

    it "charges the surcharge once per parcel on an over-max split" do
      basis = ShippingCostCalculator.basis(gb_order(zip: "IV1 1AA", grams: 5500)) # 5.5kg -> 5 + 0.5 = 2 parcels
      # base(5kg: 250+30+2=282) + base(0.5kg: 25+30+2=57) + 17*2 remote = 373
      expect(basis.order_estimate_cny).to eq(373)
    end

    it "resolves the remote-area version once for N cache-sharing orders (no N+1)" do
      orders = Array.new(5) { gb_order(zip: "IV1 1AA") } # same company/country/date, same rule

      version_queries = 0
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        # Match the data query only, not Postgres's one-time schema-introspection
        # load (which references the table name but selects from pg_attribute).
        version_queries += 1 if payload[:sql].include?('FROM "shipping_remote_area_versions"')
      end

      cache = {}
      orders.each { |o| ShippingCostCalculator.basis(o, cache: cache) }

      ActiveSupport::Notifications.unsubscribe(subscription)
      # Memoized in @cache: one lookup total, not one per order.
      expect(version_queries).to be < orders.size
      expect(version_queries).to eq(1)
    end
  end

  describe "remote-area surcharge with no configured version (nil cache path)" do
    let(:company) { create(:company) }
    let(:store) do
      create(:shopify_store, company: company, user: create(:user),
             currency: "USD", cost_fx_rate: 7.0, default_service_type: "with_battery")
    end
    let(:customer) { create(:customer, shopify_store: store) }

    def gb_order(zip:, grams: 1000)
      o = create(:order, customer: customer, shopify_store: store,
                 ordered_at: Time.utc(2026, 6, 15, 12),
                 shopify_data: { "shipping_address" => { "country_code" => "GB", "zip" => zip } })
      variant = create(:product_variant, product: create(:product, shopify_store: store), weight_grams: grams)
      create(:order_line_item, order: o, product_variant: variant, quantity: 1)
      o
    end

    before do
      v = create(:shipping_rate_card_version, company: company, country_code: "GB",
                 service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: v, zone: nil, weight_min_kg: 0, weight_max_kg: 5,
             per_kg_rate_cny: 50, flat_fee_cny: 30)
      # Deliberately NO ShippingRemoteAreaVersion — the common case (most
      # companies never configure remote areas). The lookup returns nil and
      # that nil must be cached, or every order re-queries the versions table.
    end

    it "caches the nil version lookup once for N cache-sharing orders (surcharge 0)" do
      orders = Array.new(5) { gb_order(zip: "IV1 1AA") } # normalizable postcode, but no version

      version_queries = 0
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        # Match the data query only, not Postgres's one-time schema-introspection
        # load (which references the table name but selects from pg_attribute).
        version_queries += 1 if payload[:sql].include?('FROM "shipping_remote_area_versions"')
      end

      cache = {}
      bases = orders.map { |o| ShippingCostCalculator.basis(o, cache: cache) }

      ActiveSupport::Notifications.unsubscribe(subscription)

      # No version → no surcharge, and the nil lookup is memoized: one query, not N.
      expect(bases).to all(have_attributes(remote_surcharge_cny: 0, remote_area_label: nil))
      expect(version_queries).to be < orders.size
      expect(version_queries).to eq(1)
    end
  end
end
