require "rails_helper"

RSpec.describe BackfillOrderLineItemsService do
  let(:store) { create(:shopify_store, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:product) { create(:product, shopify_store: store, shopify_product_id: 7001) }
  let!(:variant) do
    create(:product_variant, product: product, shopify_variant_id: 8001, unit_cost: 72.00)
  end

  let(:line_items_payload) do
    [
      { "id" => 6001, "variant_id" => 8001, "sku" => "PK-BL", "title" => "Black",
        "quantity" => 3, "price" => "29.00" },
      { "id" => 6002, "variant_id" => 9999, "sku" => "MYST", "title" => "Mystery",
        "quantity" => 1, "price" => "15.00" }
    ]
  end

  let!(:order) do
    create(:order, customer: customer, shopify_store: store, currency: "USD",
                   shopify_data: { "line_items" => line_items_payload })
  end

  it "creates OrderLineItem rows from orders.shopify_data" do
    expect { described_class.new(store).call }.to change(OrderLineItem, :count).by(2)
  end

  it "snapshots unit_cost converted from CNY to store currency" do
    described_class.new(store).call
    li = order.order_line_items.find_by(shopify_line_item_id: 6001)
    # 72 CNY / 7.2 = 10.00 USD
    expect(li.unit_cost_snapshot).to eq(10.00)
    expect(li.product_variant).to eq(variant)
  end

  it "leaves snapshot nil when store.cost_fx_rate is nil" do
    store.update!(cost_fx_rate: nil)
    described_class.new(store).call
    li = order.order_line_items.find_by(shopify_line_item_id: 6001)
    expect(li.unit_cost_snapshot).to be_nil
  end

  it "leaves snapshot null when variant is unknown" do
    described_class.new(store).call
    li = order.order_line_items.find_by(shopify_line_item_id: 6002)
    expect(li.unit_cost_snapshot).to be_nil
    expect(li.product_variant).to be_nil
  end

  it "is idempotent — does not duplicate" do
    described_class.new(store).call
    expect { described_class.new(store).call }.not_to change(OrderLineItem, :count)
  end

  it "does not overwrite a previously set snapshot" do
    described_class.new(store).call
    order.order_line_items.find_by(shopify_line_item_id: 6001).update!(unit_cost_snapshot: 7.77)

    described_class.new(store).call
    expect(order.order_line_items.find_by(shopify_line_item_id: 6001).unit_cost_snapshot).to eq(7.77)
  end

  it "returns counts" do
    result = described_class.new(store).call
    expect(result[:orders]).to eq(1)
    expect(result[:snapshotted]).to eq(1)
  end

  describe "estimated shipping backfill" do
    # Separate store configured for ShippingCostCalculator compatibility.
    let(:shipping_store) do
      create(:shopify_store, currency: "USD", cost_fx_rate: 7.0,
             default_service_type: "with_battery")
    end
    let(:shipping_customer) { create(:customer, shopify_store: shipping_store) }

    # Rate card: 0.201–0.45 kg → cny = 0.3*92 + 23 = 50.6 → usd = 50.6/7.0 = 7.23
    before do
      version = create(:shipping_rate_card_version,
                       company: shipping_store.company,
                       country_code: "US",
                       service_type: "with_battery",
                       effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: version,
             weight_min_kg: 0.201, weight_max_kg: 0.45,
             per_kg_rate_cny: 92.0, flat_fee_cny: 23.0)
    end

    def order_with_weighted_line(estimated: nil, actual: nil)
      order = create(:order, customer: shipping_customer, shopify_store: shipping_store,
                     ordered_at: shipping_store.active_timezone.local(2026, 4, 15, 12),
                     estimated_shipping_cost: estimated, actual_shipping_cost: actual,
                     shopify_data: { "shipping_address" => { "country_code" => "US" } })
      product = create(:product, shopify_store: shipping_store)
      variant = create(:product_variant, product: product, weight_grams: 300)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      order
    end

    it "fills estimated_shipping_cost when nil and reports shipping_filled: 1" do
      order = order_with_weighted_line
      result = described_class.new(shipping_store).call
      expect(order.reload.estimated_shipping_cost).to eq(7.23)
      expect(result[:shipping_filled]).to eq(1)
    end

    it "does not overwrite an existing estimated_shipping_cost" do
      order = order_with_weighted_line(estimated: 5.00)
      described_class.new(shipping_store).call
      expect(order.reload.estimated_shipping_cost).to eq(5.00)
    end

    it "never touches actual_shipping_cost" do
      order = order_with_weighted_line(actual: 8.50)
      described_class.new(shipping_store).call
      expect(order.reload.actual_shipping_cost).to eq(8.50)
    end
  end
end
