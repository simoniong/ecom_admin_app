require "rails_helper"

RSpec.describe RepairShippingEstimatesService do
  let(:company) { create(:company) }
  let(:user)    { create(:user) }
  let(:store) do
    create(:shopify_store, user: user, company: company,
           currency: "USD", cost_fx_rate: 7.0, default_service_type: "with_battery")
  end
  let(:customer) { create(:customer, shopify_store: store) }
  let(:product)  { create(:product, shopify_store: store) }

  # ¥10/kg + ¥23 flat + ¥2 operation fee, converted at 7.0 CNY/USD.
  before do
    version = create(:shipping_rate_card_version, company: company, country_code: "US",
                     service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
    create(:shipping_rate_card_rate, version: version, zone: nil,
           weight_min_kg: 0, weight_max_kg: 5, per_kg_rate_cny: 10, flat_fee_cny: 23)
  end

  def usd_for(weight_kg)
    ((BigDecimal(weight_kg.to_s) * 10 + 23 + 2) / 7.0).round(2)
  end

  # An order whose line items were created at distinct times, mimicking a
  # post-purchase upsell arriving in a later webhook.
  def build_order(weights_grams:, estimated_shipping_cost:)
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: Time.utc(2026, 4, 15, 12),
                   shopify_data: { "shipping_address" => { "country_code" => "US" } },
                   estimated_shipping_cost: estimated_shipping_cost)
    weights_grams.each_with_index do |grams, i|
      variant = create(:product_variant, product: product, weight_grams: grams)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1,
             created_at: Time.utc(2026, 4, 15, 12, 0, i))
    end
    order
  end

  describe "the partial-order proof" do
    # 0.8 kg alone prices to the frozen value; the real order is 0.8 + 0.4 kg.
    let!(:order) { build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: usd_for(0.8)) }

    it "reports the repair without writing when apply is false" do
      result = described_class.new.call

      expect(result[:applied]).to be false
      expect(result[:unexplained]).to be_empty
      expect(result[:repairs].size).to eq(1)

      repair = result[:repairs].first
      expect(repair.order_name).to eq(order.name)
      expect(repair.frozen).to eq(usd_for(0.8))
      expect(repair.repaired).to eq(usd_for(1.2))
      expect(repair.proof).to eq(:partial_order)
      expect(repair.detail).to include("priced 1/2 items")

      expect(order.reload.estimated_shipping_cost).to eq(usd_for(0.8))
    end

    it "writes the full-order estimate when apply is true" do
      described_class.new(apply: true).call

      expect(order.reload.estimated_shipping_cost).to eq(usd_for(1.2))
    end

    it "is idempotent — a second apply run finds nothing left to repair" do
      described_class.new(apply: true).call
      result = described_class.new(apply: true).call

      expect(result[:repairs]).to be_empty
      expect(result[:unexplained]).to be_empty
      expect(order.reload.estimated_shipping_cost).to eq(usd_for(1.2))
    end
  end

  it "proves a two-item prefix on an order that grew twice" do
    order = build_order(weights_grams: [ 800, 400, 300 ], estimated_shipping_cost: usd_for(1.2))

    result = described_class.new(apply: true).call

    expect(result[:repairs].first.detail).to include("priced 2/3 items")
    expect(order.reload.estimated_shipping_cost).to eq(usd_for(1.5))
  end

  it "leaves an order alone when no subset reproduces the frozen value" do
    # Diverges for some other reason (a SKU weight or rate card moved), so the
    # cause is not proven and rewriting it would replace a historical cost.
    order = build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: 99.99)

    result = described_class.new(apply: true).call

    expect(result[:repairs]).to be_empty
    expect(result[:unexplained].map(&:order_name)).to eq([ order.name ])
    expect(order.reload.estimated_shipping_cost).to eq(99.99)
  end

  it "ignores orders whose estimate already matches the full order" do
    order = build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: usd_for(1.2))

    result = described_class.new(apply: true).call

    expect(result[:repairs]).to be_empty
    expect(result[:unexplained]).to be_empty
    expect(order.reload.estimated_shipping_cost).to eq(usd_for(1.2))
  end

  it "cannot prove a single-item order by prefix, and reports it unexplained" do
    order = build_order(weights_grams: [ 800 ], estimated_shipping_cost: 99.99)

    result = described_class.new(apply: true).call

    expect(result[:repairs]).to be_empty
    expect(result[:unexplained].map(&:order_name)).to eq([ order.name ])
    expect(order.reload.estimated_shipping_cost).to eq(99.99)
  end

  it "skips an order with a weightless line item rather than pricing it as zero" do
    order = build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: usd_for(0.8))
    order.order_line_items.order(:created_at).last.product_variant.update!(weight_grams: nil)

    result = described_class.new(apply: true).call

    expect(result[:repairs]).to be_empty
    expect(result[:unexplained]).to be_empty
    expect(order.reload.estimated_shipping_cost).to eq(usd_for(0.8))
  end

  it "honours the store_ids filter" do
    build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: usd_for(0.8))
    other = create(:shopify_store, user: user, company: company,
                   currency: "USD", cost_fx_rate: 7.0, default_service_type: "with_battery")

    result = described_class.new(apply: true, store_ids: [ other.id ]).call

    expect(result[:scanned]).to eq(0)
    expect(result[:repairs]).to be_empty
  end

  it "honours the from filter on ordered_at" do
    build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: usd_for(0.8))

    result = described_class.new(apply: true, from: Date.new(2026, 6, 1)).call

    expect(result[:scanned]).to eq(0)
    expect(result[:repairs]).to be_empty
  end

  describe "the operation-fee proof" do
    # OPERATION_FEE_CNY was folded into every priced parcel on 2026-07-17 so an
    # on-target order would read ~¥0 variance instead of a standing phantom
    # overcharge. Estimates frozen before that never got it, and on staging
    # 2517 orders sat exactly one fee short (12 heavier ones exactly two, being
    # split into two parcels).
    let(:fee) { ShippingCostCalculator::OPERATION_FEE_CNY }

    # 0.8 kg: 0.8 * 10 + 23 + 2 = ¥33.00 -> $4.71. Without the fee, ¥31.00 -> $4.43.
    def frozen_without_fees(weight_kg, fees)
      ((BigDecimal(weight_kg.to_s) * 10 + 23 + 2 - (fee * fees)) / 7.0).round(2)
    end

    it "proves and repairs an estimate missing one handling fee" do
      order = build_order(weights_grams: [ 800 ], estimated_shipping_cost: frozen_without_fees(0.8, 1))

      result = described_class.new(apply: true).call

      repair = result[:repairs].first
      expect(repair.proof).to eq(:operation_fee)
      expect(repair.detail).to include("missing 1 × ¥2 handling fee")
      expect(order.reload.estimated_shipping_cost).to eq(usd_for(0.8))
    end

    it "proves an estimate missing two handling fees (an order split over two parcels)" do
      order = build_order(weights_grams: [ 800 ], estimated_shipping_cost: frozen_without_fees(0.8, 2))

      result = described_class.new(apply: true).call

      expect(result[:repairs].first.detail).to include("missing 2 × ¥2 handling fees")
      expect(order.reload.estimated_shipping_cost).to eq(usd_for(0.8))
    end

    it "applies to single-item orders, which the prefix proof can never reach" do
      order = build_order(weights_grams: [ 800 ], estimated_shipping_cost: frozen_without_fees(0.8, 1))

      described_class.new(apply: true).call

      expect(order.reload.estimated_shipping_cost).to eq(usd_for(0.8))
    end

    it "does not invent a proof for an arbitrary shortfall" do
      order = build_order(weights_grams: [ 800 ], estimated_shipping_cost: 4.00)

      result = described_class.new(apply: true).call

      expect(result[:repairs]).to be_empty
      expect(result[:unexplained].map(&:order_name)).to eq([ order.name ])
      expect(order.reload.estimated_shipping_cost).to eq(4.00)
    end

    it "prefers the partial-order proof when both could match" do
      # Two items where the first alone reproduces the frozen value: the more
      # specific proof wins, though both would write the same repaired figure.
      order = build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: usd_for(0.8))

      result = described_class.new(apply: true).call

      expect(result[:repairs].first.proof).to eq(:partial_order)
      expect(order.reload.estimated_shipping_cost).to eq(usd_for(1.2))
    end
  end

  it "stores the repaired CNY alongside the store-currency figure" do
    order = build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: usd_for(0.8))

    described_class.new(apply: true).call

    # 1.2 kg -> 1.2 * 10 + 23 + 2 = ¥37.00, not a back-conversion of $5.29.
    expect(order.reload.estimated_shipping_cost_cny).to eq(37.00)
  end
end
