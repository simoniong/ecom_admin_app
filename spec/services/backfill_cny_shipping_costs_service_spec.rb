require "rails_helper"

RSpec.describe BackfillCnyShippingCostsService do
  let(:company)  { create(:company) }
  let(:user)     { create(:user) }
  let(:store) do
    create(:shopify_store, user: user, company: company, currency: "USD",
           cost_fx_rate: 7.0, default_service_type: "with_battery")
  end
  let(:customer) { create(:customer, shopify_store: store) }
  let(:product)  { create(:product, shopify_store: store) }

  before do
    version = create(:shipping_rate_card_version, company: company, country_code: "US",
                     service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
    create(:shipping_rate_card_rate, version: version, zone: nil,
           weight_min_kg: 0, weight_max_kg: 5, per_kg_rate_cny: 10, flat_fee_cny: 23)
  end

  # 1 kg → 10 + 23 + 2 = ¥35.00 → $5.00 exactly.
  def build_order(estimated_shipping_cost:, weight_grams: 1000)
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: Time.utc(2026, 4, 15, 12),
                   shopify_data: { "shipping_address" => { "country_code" => "US" } },
                   estimated_shipping_cost: estimated_shipping_cost)
    variant = create(:product_variant, product: product, weight_grams: weight_grams)
    create(:order_line_item, order: order, product_variant: variant, quantity: 1,
           weight_grams_snapshot: weight_grams)
    order
  end

  describe "the estimate side" do
    it "stores the rate card's own CNY when the recomputation matches the frozen figure" do
      order = build_order(estimated_shipping_cost: 5.00)

      result = described_class.new(apply: true).call

      expect(order.reload.estimated_shipping_cost_cny).to eq(35.00)
      expect(result).to include(estimate_proven: 1, estimate_converted: 0)
    end

    it "converts instead when the recomputation disagrees, leaving the displayed number unmoved" do
      # A frozen figure the current basis no longer reproduces: it must not be
      # silently repriced, only expressed in CNY exactly as it renders today.
      order = build_order(estimated_shipping_cost: 9.99)

      result = described_class.new(apply: true).call

      expect(order.reload.estimated_shipping_cost_cny).to eq(69.93) # 9.99 * 7.0
      expect(result).to include(estimate_proven: 0, estimate_converted: 1)
    end

    it "leaves the column NULL when the store has no usable fx rate" do
      order = build_order(estimated_shipping_cost: 5.00)
      store.update_columns(cost_fx_rate: nil)

      result = described_class.new(apply: true).call

      expect(order.reload.estimated_shipping_cost_cny).to be_nil
      expect(result).to include(estimate_unavailable: 1)
    end
  end

  describe "the actual side" do
    it "copies the parcels' own CNY total rather than converting" do
      order = build_order(estimated_shipping_cost: 5.00)
      create(:parcel, shopify_store: store, order: order, cost_cny: 128.04, cost_amount: 18.92)
      order.update_columns(actual_shipping_cost_cny: nil)

      described_class.new(apply: true).call

      # 18.92 * 7.0 would be 132.44 — the point is that it is not converted.
      expect(order.reload.actual_shipping_cost_cny).to eq(128.04)
    end
  end

  it "writes nothing on a dry run" do
    order = build_order(estimated_shipping_cost: 5.00)

    result = described_class.new.call

    expect(order.reload.estimated_shipping_cost_cny).to be_nil
    expect(result).to include(applied: false, estimate_proven: 1)
  end

  it "is idempotent" do
    build_order(estimated_shipping_cost: 5.00)
    described_class.new(apply: true).call

    result = described_class.new(apply: true).call

    expect(result).to include(estimate_proven: 0, estimate_converted: 0, actual_filled: 0)
  end

  it "honours the store filter" do
    build_order(estimated_shipping_cost: 5.00)
    other = create(:shopify_store, user: user, company: company)

    result = described_class.new(apply: true, store_ids: [ other.id ]).call

    expect(result).to include(scanned: 0)
  end
end
