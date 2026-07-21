require "rails_helper"
RSpec.describe PackageAutoBuilder do
  let(:store) { create(:shopify_store, packing_enabled: true, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:order) do
    o = create(:order, shopify_store: store, financial_status: "paid")
    create(:order_line_item, order: o, sku_at_sale: "WP10155-L", title_at_sale: "Puzzle", quantity: 2)
    o
  end

  it "creates a pending_review package with the store's starting number and copied items" do
    described_class.new(order).call
    pkg = store.packages.find_by(order: order)
    expect(pkg).to be_present
    expect(pkg).to have_state(:pending_review)
    expect(pkg.number).to eq(2013094)
    expect(pkg.package_items.pluck(:sku, :quantity)).to contain_exactly([ "WP10155-L", 2 ])
    expect(store.reload.package_number_seq).to eq(2013095)
  end

  it "increments the sequence for the next package" do
    described_class.new(order).call
    order2 = create(:order, shopify_store: store, financial_status: "paid")
    described_class.new(order2).call
    expect(store.packages.find_by(order: order2).number).to eq(2013095)
  end

  it "is idempotent — a second call does not create a duplicate" do
    described_class.new(order).call
    expect { described_class.new(order).call }.not_to change { Package.count }
  end

  it "does not build when packing is disabled" do
    store.update_columns(packing_enabled: false)
    described_class.new(order).call
    expect(store.packages.count).to eq(0)
  end

  it "does not build for an unpaid order" do
    order.update!(financial_status: "pending")
    described_class.new(order).call
    expect(store.packages.count).to eq(0)
  end

  it "does not build for a cancelled order" do
    order.update!(shopify_data: { "cancelled_at" => "2026-07-20T00:00:00Z" })
    described_class.new(order).call
    expect(store.packages.count).to eq(0)
  end

  it "does not build for a fully refunded order" do
    order.update!(financial_status: "refunded")
    described_class.new(order).call
    expect(store.packages.count).to eq(0)
  end

  it "refunds an existing package when the order is fully refunded" do
    described_class.new(order).call
    pkg = store.packages.find_by(order: order)
    order.update!(financial_status: "refunded")
    described_class.new(order).call
    expect(pkg.reload).to have_state(:refunded)
  end

  it "does not refund on a partial refund" do
    described_class.new(order).call
    pkg = store.packages.find_by(order: order)
    order.update!(financial_status: "partially_refunded")
    described_class.new(order).call
    expect(pkg.reload).not_to have_state(:refunded)
  end

  it "swallows a mid-build error instead of letting it propagate into order sync" do
    allow_any_instance_of(Package).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(Package.new))

    expect { described_class.new(order).call }.not_to raise_error
    expect(described_class.new(order).call).to be_nil
    expect(store.packages.count).to eq(0)
  end

  it "does not consume a sequence number when it bails inside the lock because the package already exists" do
    described_class.new(order).call
    expect(store.reload.package_number_seq).to eq(2013095)

    # Call build_package directly (bypassing do_call's outer fast-path
    # check) to prove the authoritative in-lock re-check on its own sees
    # the already-built package and bails WITHOUT bumping the sequence —
    # this is what protects against the same-order concurrent race.
    expect { described_class.new(order).send(:build_package) }.not_to change { store.reload.package_number_seq }
    expect(store.packages.where(order: order).count).to eq(1)
  end

  it "does not raise and does not create a duplicate when create! collides with an already-built package (RecordNotUnique)" do
    described_class.new(order).call
    expect(store.packages.where(order: order).count).to eq(1)

    # Force the in-lock existence re-check to miss (simulating a race window)
    # so the code proceeds to create!, which must hit the unique order_id
    # index and be rescued as a clean no-op.
    allow(store.packages).to receive(:exists?).with(order_id: order.id).and_return(false)

    builder = described_class.new(order)
    expect { builder.send(:build_package) }.not_to raise_error
    expect(Package.count).to eq(1)
  end
end
