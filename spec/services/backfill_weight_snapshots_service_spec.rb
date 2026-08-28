require "rails_helper"

RSpec.describe BackfillWeightSnapshotsService do
  let(:store)   { create(:shopify_store) }
  let(:product) { create(:product, shopify_store: store) }
  let(:order)   { create(:order, shopify_store: store) }

  def line_item(weight_grams:, snapshot: nil)
    variant = create(:product_variant, product: product, weight_grams: weight_grams)
    create(:order_line_item, order: order, product_variant: variant,
           quantity: 1, weight_grams_snapshot: snapshot)
  end

  it "fills an empty snapshot from the variant's current weight" do
    li = line_item(weight_grams: 810)

    result = described_class.new.call

    expect(li.reload.weight_grams_snapshot).to eq(810)
    expect(result).to include(filled: 1, skipped_no_weight: 0, refresh: false)
  end

  it "leaves an existing snapshot alone by default, even when the variant moved" do
    li = line_item(weight_grams: 900, snapshot: 810)

    result = described_class.new.call

    expect(li.reload.weight_grams_snapshot).to eq(810)
    expect(result[:filled]).to eq(0)
  end

  it "overwrites an existing snapshot with refresh: true" do
    li = line_item(weight_grams: 900, snapshot: 810)

    result = described_class.new(refresh: true).call

    expect(li.reload.weight_grams_snapshot).to eq(900)
    expect(result).to include(filled: 1, refresh: true)
  end

  it "skips a line whose variant has no usable weight rather than writing zero" do
    li = line_item(weight_grams: nil)

    result = described_class.new.call

    expect(li.reload.weight_grams_snapshot).to be_nil
    expect(result).to include(filled: 0, skipped_no_weight: 1)
  end

  it "does not touch updated_at" do
    li = line_item(weight_grams: 810)
    before = li.updated_at

    described_class.new.call

    expect(li.reload.updated_at).to eq(before)
  end

  it "honours the store filter" do
    line_item(weight_grams: 810)
    other = create(:shopify_store)

    result = described_class.new(store_ids: [ other.id ]).call

    expect(result).to include(scanned: 0, filled: 0)
  end
end
