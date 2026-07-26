require "rails_helper"

RSpec.describe PackageSplitter do
  let(:user)     { create(:user) }
  let(:company)  { user.companies.first }
  let(:store)    { create(:shopify_store, user: user, company: company, packing_enabled: true,
                          package_prefix: "XMBDE", package_number_start: 2013094).tap { |s|
                          s.update_columns(packing_enabled_at: 1.year.ago) } }
  let(:customer) { create(:customer, shopify_store: store) }
  let(:order)    { create(:order, customer: customer, shopify_store: store) }
  let(:oli_a)    { create(:order_line_item, order: order) }
  let(:oli_b)    { create(:order_line_item, order: order) }

  let(:source) do
    pkg = create(:package, shopify_store: store, order: order, number: 100,
                 aasm_state: "pending_process", logistics_channel_id: nil,
                 shipping_address_snapshot: { "name" => "Amy", "city" => "Paris" }, address_overridden: true)
    create(:package_item, package: pkg, order_line_item: oli_a, sku: "A", title: "Art A",
           quantity: 3, refunded_quantity: 0, customs_name_zh: "畫", customs_overridden: true)
    create(:package_item, package: pkg, order_line_item: oli_b, sku: "B", title: "Art B",
           quantity: 2, refunded_quantity: 0)
    pkg
  end

  before { store.update_columns(package_number_seq: 2013094) }

  it "carves one new box, moving allocated units and leaving the remainder on the source" do
    result = described_class.new(source, { oli_a.id => [ 1 ], oli_b.id => [ 2 ] }).call

    expect(result.success?).to be(true)
    expect(result.new_packages.size).to eq(1)
    box = result.new_packages.first
    expect(box.aasm_state).to eq("pending_process")
    expect(box.number).to eq(2013094)
    expect(store.reload.package_number_seq).to eq(2013095)
    # new box items
    expect(box.package_items.pluck(:sku, :quantity)).to contain_exactly([ "A", 1 ], [ "B", 2 ])
    # source remainder: A 3→2, B fully moved (2→0) so its source item is deleted
    expect(source.reload.package_items.pluck(:sku, :quantity)).to contain_exactly([ "A", 2 ])
  end

  it "inherits address+override, logistics, and per-item customs+override onto the new box" do
    source.update!(logistics_channel_id: nil)
    box = described_class.new(source, { oli_a.id => [ 1 ], oli_b.id => [ 0 ] }).call.new_packages.first
    expect(box.shipping_address_snapshot).to eq("name" => "Amy", "city" => "Paris")
    expect(box.address_overridden).to be(true)
    a_item = box.package_items.find_by(sku: "A")
    expect(a_item.customs_name_zh).to eq("畫")
    expect(a_item.customs_overridden).to be(true)
  end

  it "keeps the quantity/refunded invariants: only shippable units move, refunded stay on source" do
    source.package_items.find_by(sku: "A").update!(quantity: 3, refunded_quantity: 1) # shippable = 2
    box = described_class.new(source, { oli_a.id => [ 2 ], oli_b.id => [ 0 ] }).call.new_packages.first
    expect(box.package_items.find_by(sku: "A").attributes.values_at("quantity", "refunded_quantity")).to eq([ 2, 0 ])
    # source A: quantity 3 - 2 moved = 1 (the single refunded unit), refunded_quantity unchanged
    src_a = source.reload.package_items.find_by(sku: "A")
    expect([ src_a.quantity, src_a.refunded_quantity ]).to eq([ 1, 1 ])
  end

  it "supports multiple new boxes in one call" do
    result = described_class.new(source, { oli_a.id => [ 1, 1 ], oli_b.id => [ 0, 1 ] }).call
    expect(result.success?).to be(true)
    expect(result.new_packages.size).to eq(2)
    expect(result.new_packages.map(&:number)).to eq([ 2013094, 2013095 ])
    # A: 3 - (1+1) = 1 remains. B: 2 - (0+1) = 1 remains (moved_total for B is
    # only 1, not 2, given the literal allocation { oli_b.id => [0, 1] }) —
    # both survive; B is NOT fully moved, so it is not destroyed.
    expect(source.reload.package_items.pluck(:sku, :quantity)).to contain_exactly([ "A", 1 ], [ "B", 1 ])
  end

  describe "validation (no persistence on failure)" do
    it "rejects an empty box (a box receiving 0 total units)" do
      result = described_class.new(source, { oli_a.id => [ 0 ], oli_b.id => [ 0 ] }).call
      expect(result.success?).to be(false)
      expect(result.errors).to include(:empty_box)
      expect(store.packages.where(order_id: order.id).count).to eq(1)
    end

    it "rejects when the source would keep no shippable units (empty source)" do
      result = described_class.new(source, { oli_a.id => [ 3 ], oli_b.id => [ 2 ] }).call
      expect(result.errors).to include(:empty_source)
    end

    it "rejects over-allocation beyond an item's shippable quantity" do
      result = described_class.new(source, { oli_a.id => [ 4 ], oli_b.id => [ 0 ] }).call
      expect(result.errors).to include(:over_allocated)
    end

    it "rejects negative units" do
      result = described_class.new(source, { oli_a.id => [ -1 ], oli_b.id => [ 2 ] }).call
      expect(result.errors).to include(:negative)
    end

    it "rejects ragged allocation arrays (uneven box counts)" do
      result = described_class.new(source, { oli_a.id => [ 1, 0 ], oli_b.id => [ 1 ] }).call
      expect(result.errors).to include(:ragged)
    end

    it "rejects an unknown line item id" do
      result = described_class.new(source, { "not-a-real-id" => [ 1 ] }).call
      expect(result.errors).to include(:unknown_item)
    end

    it "rejects empty allocations" do
      expect(described_class.new(source, {}).call.errors).to include(:empty)
    end
  end
end
