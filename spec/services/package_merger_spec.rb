require "rails_helper"

RSpec.describe PackageMerger do
  let(:user)     { create(:user) }
  let(:company)  { user.companies.first }
  let(:store)    { create(:shopify_store, user: user, company: company) }
  let(:customer) { create(:customer, shopify_store: store) }
  let(:order)    { create(:order, customer: customer, shopify_store: store) }
  let(:oli_a)    { create(:order_line_item, order: order) }

  def box(number, addr: { "city" => "Paris" }, channel_id: nil)
    create(:package, shopify_store: store, order: order, number: number,
           aasm_state: "pending_process", shipping_address_snapshot: addr,
           logistics_channel_id: channel_id)
  end

  it "collapses siblings into the lowest-numbered survivor, summing items by line item" do
    survivor = box(10)
    create(:package_item, package: survivor, order_line_item: oli_a, sku: "A", quantity: 2, refunded_quantity: 1)
    other = box(11)
    create(:package_item, package: other, order_line_item: oli_a, sku: "A", quantity: 3, refunded_quantity: 0)

    result = described_class.new(survivor).call

    expect(result).to eq(survivor)
    expect(store.packages.where(order_id: order.id).count).to eq(1)
    item = survivor.reload.package_items.find_by(order_line_item_id: oli_a.id)
    expect([ item.quantity, item.refunded_quantity ]).to eq([ 5, 1 ]) # 2+3, 1+0
  end

  it "moves a line item that the survivor lacks, then destroys the absorbed package" do
    survivor = box(10)
    other = box(11)
    oli_b = create(:order_line_item, order: order)
    create(:package_item, package: other, order_line_item: oli_b, sku: "B", quantity: 4)

    described_class.new(order).call

    expect(store.packages.where(order_id: order.id).count).to eq(1)
    expect(survivor.reload.package_items.pluck(:sku, :quantity)).to contain_exactly([ "B", 4 ])
  end

  it "keeps the survivor's package-level fields, discarding absorbed ones" do
    channel = create(:logistics_channel)
    survivor = box(10, addr: { "city" => "Survivor" }, channel_id: channel.id)
    box(11, addr: { "city" => "Absorbed" }, channel_id: nil)
    described_class.new(survivor).call
    expect(survivor.reload.shipping_address_snapshot).to eq("city" => "Survivor")
    expect(survivor.logistics_channel_id).to eq(channel.id)
  end

  describe "#conflict?" do
    it "is true when siblings differ on address or logistics" do
      s = box(10, addr: { "city" => "Paris" })
      box(11, addr: { "city" => "Lyon" })
      expect(described_class.new(s).conflict?).to be(true)
    end

    it "is false when siblings agree" do
      s = box(10, addr: { "city" => "Paris" })
      box(11, addr: { "city" => "Paris" })
      expect(described_class.new(s).conflict?).to be(false)
    end

    it "is false for a lone package (nothing to merge)" do
      expect(described_class.new(box(10)).conflict?).to be(false)
    end
  end

  it "only merges pending_process siblings, leaving a held sibling untouched" do
    survivor = box(10)
    held = box(11)
    held.update!(aasm_state: "held", held_from: "pending_process")
    described_class.new(survivor).call
    expect(store.packages.where(order_id: order.id).pluck(:aasm_state)).to contain_exactly("pending_process", "held")
  end
end
