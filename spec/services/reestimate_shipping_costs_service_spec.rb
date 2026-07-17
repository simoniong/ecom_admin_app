require "rails_helper"

RSpec.describe ReestimateShippingCostsService do
  let(:company) { create(:company) }
  let(:user) { create(:user) }
  let(:store) do
    create(:shopify_store, user: user, company: company,
           currency: "USD", cost_fx_rate: 7.0, default_service_type: "with_battery")
  end
  let(:customer) { create(:customer, shopify_store: store) }

  # Builds an order with a single weighted line item, destination country
  # carried by shipping_address (default) or billing_address only.
  def build_order(country:, weight_grams: 2500, ordered_on: Date.new(2026, 4, 15),
                  billing_only: false, estimated_shipping_cost: nil, store: self.store)
    address_key = billing_only ? "billing_address" : "shipping_address"
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: store.active_timezone.local(ordered_on.year, ordered_on.month, ordered_on.day, 12),
                   shopify_data: { address_key => { "country_code" => country } },
                   estimated_shipping_cost: estimated_shipping_cost)
    product = create(:product, shopify_store: store)
    variant = create(:product_variant, product: product, weight_grams: weight_grams)
    create(:order_line_item, order: order, product_variant: variant, quantity: 1)
    order
  end

  def build_rate_card(country:, per_kg:, flat:, from: Date.new(2026, 1, 1), min: 0, max: 5)
    version = create(:shipping_rate_card_version, company: company, country_code: country,
                     service_type: "with_battery", effective_from: from)
    create(:shipping_rate_card_rate, version: version, zone: nil, weight_min_kg: min, weight_max_kg: max,
           per_kg_rate_cny: per_kg, flat_fee_cny: flat)
    version
  end

  describe "overwriting a stale estimate" do
    it "recomputes and overwrites an existing estimated_shipping_cost with the current rate-card value" do
      build_rate_card(country: "AU", per_kg: 30, flat: 25)
      order = build_order(country: "AU", weight_grams: 2500, estimated_shipping_cost: 999.99)

      current_estimate = ShippingCostCalculator.estimate(order)
      expect(current_estimate).to be_present
      expect(current_estimate).not_to eq(999.99) # sanity: the frozen value really is stale

      result = described_class.new.call

      expect(order.reload.estimated_shipping_cost).to eq(current_estimate)
      expect(result).to eq(scanned: 1, updated: 1, skipped: 0, skipped_details: [])
    end
  end

  describe "country filter" do
    it "reestimates only orders whose resolved destination country matches, honoring shipping-then-billing" do
      build_rate_card(country: "AU", per_kg: 30, flat: 25)
      build_rate_card(country: "US", per_kg: 92, flat: 23, min: 0.201, max: 0.45)

      au_order = build_order(country: "AU", weight_grams: 2500, estimated_shipping_cost: 1.11)
      au_billing_only_order = build_order(country: "AU", weight_grams: 2500, billing_only: true, estimated_shipping_cost: 2.22)
      us_order = build_order(country: "US", weight_grams: 300, estimated_shipping_cost: 3.33)

      au_expected = ShippingCostCalculator.estimate(au_order)
      au_billing_expected = ShippingCostCalculator.estimate(au_billing_only_order)

      result = described_class.new(country: "AU").call

      expect(order_value(au_order)).to eq(au_expected)
      expect(order_value(au_billing_only_order)).to eq(au_billing_expected)
      expect(order_value(us_order)).to eq(3.33) # untouched
      expect(result).to eq(scanned: 2, updated: 2, skipped: 0, skipped_details: [])
    end
  end

  describe "from filter" do
    it "does not touch orders placed before the from date" do
      build_rate_card(country: "AU", per_kg: 30, flat: 25)
      old_order = build_order(country: "AU", ordered_on: Date.new(2026, 1, 1), estimated_shipping_cost: 1.11)
      new_order = build_order(country: "AU", ordered_on: Date.new(2026, 4, 15), estimated_shipping_cost: 2.22)

      new_expected = ShippingCostCalculator.estimate(new_order)

      result = described_class.new(from: Date.new(2026, 3, 1)).call

      expect(order_value(old_order)).to eq(1.11) # untouched
      expect(order_value(new_order)).to eq(new_expected)
      expect(result).to eq(scanned: 1, updated: 1, skipped: 0, skipped_details: [])
    end
  end

  describe "store_ids filter" do
    it "only reestimates orders belonging to the given stores" do
      build_rate_card(country: "AU", per_kg: 30, flat: 25)
      other_store = create(:shopify_store, user: user, company: company,
                           currency: "USD", cost_fx_rate: 7.0, default_service_type: "with_battery")
      other_customer = create(:customer, shopify_store: other_store)

      in_scope = build_order(country: "AU", estimated_shipping_cost: 1.11)
      out_of_scope = create(:order, customer: other_customer, shopify_store: other_store,
                            ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                            shopify_data: { "shipping_address" => { "country_code" => "AU" } },
                            estimated_shipping_cost: 2.22)
      product = create(:product, shopify_store: other_store)
      variant = create(:product_variant, product: product, weight_grams: 2500)
      create(:order_line_item, order: out_of_scope, product_variant: variant, quantity: 1)

      in_scope_expected = ShippingCostCalculator.estimate(in_scope)

      result = described_class.new(store_ids: [ store.id ]).call

      expect(order_value(in_scope)).to eq(in_scope_expected)
      expect(order_value(out_of_scope)).to eq(2.22) # untouched — different store
      expect(result).to eq(scanned: 1, updated: 1, skipped: 0, skipped_details: [])
    end
  end

  describe "when the current estimate is nil" do
    it "skips the order and leaves its existing value intact rather than clearing it" do
      # Band 1.0..2.0kg: a 0.3kg order is below the min and not over the max,
      # so ShippingCostCalculator cleanly returns nil (no band matches, no split triggered).
      build_rate_card(country: "AU", per_kg: 30, flat: 25, min: 1.0, max: 2.0)
      order = build_order(country: "AU", weight_grams: 300, estimated_shipping_cost: 42.0)
      expect(ShippingCostCalculator.estimate(order)).to be_nil

      result = described_class.new.call

      expect(order_value(order)).to eq(42.0)
      expect(result).to eq(
        scanned: 1, updated: 0, skipped: 1,
        skipped_details: [ { order_id: order.id, order_name: order.name, country: "AU", reason: :no_matching_band } ]
      )
    end
  end

  describe "skipped_details reasons" do
    it "reports order id/name, country and the specific reason each order was skipped" do
      # No rate card at all for GB → :no_rate_card
      no_card = build_order(country: "GB", estimated_shipping_cost: 1.0)
      # AU rate card exists, but this order has no line-item weight → :no_weight
      build_rate_card(country: "AU", per_kg: 30, flat: 25)
      no_weight = create(:order, customer: customer, shopify_store: store,
                         ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                         shopify_data: { "shipping_address" => { "country_code" => "AU" } },
                         estimated_shipping_cost: 2.0)
      # An order with no destination country at all → :no_country
      no_country = create(:order, customer: customer, shopify_store: store,
                          ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                          shopify_data: {}, estimated_shipping_cost: 3.0)

      result = described_class.new.call

      expect(result[:skipped]).to eq(3)
      expect(result[:skipped_details]).to contain_exactly(
        { order_id: no_card.id, order_name: no_card.name, country: "GB", reason: :no_rate_card },
        { order_id: no_weight.id, order_name: no_weight.name, country: "AU", reason: :no_weight },
        { order_id: no_country.id, order_name: no_country.name, country: nil, reason: :no_country }
      )
      # nothing was cleared
      expect(order_value(no_card)).to eq(1.0)
      expect(order_value(no_weight)).to eq(2.0)
      expect(order_value(no_country)).to eq(3.0)
    end
  end

  describe "return value" do
    it "reports accurate scanned/updated/skipped counts across a mixed batch" do
      build_rate_card(country: "AU", per_kg: 30, flat: 25, min: 1.0, max: 2.0)
      updatable = build_order(country: "AU", weight_grams: 1500, estimated_shipping_cost: 1.0)
      unestimable = build_order(country: "AU", weight_grams: 300, estimated_shipping_cost: 2.0) # below band min → nil

      result = described_class.new.call

      expect(result[:scanned]).to eq(2)
      expect(result[:updated]).to eq(1)
      expect(result[:skipped]).to eq(1)
      expect(order_value(updatable)).not_to eq(1.0)
      expect(order_value(unestimable)).to eq(2.0)
    end
  end

  def order_value(order)
    order.reload.estimated_shipping_cost
  end
end
