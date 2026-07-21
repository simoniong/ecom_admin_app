require "rails_helper"
RSpec.describe PackageAutoBuilder do
  # packing_enabled: true is set at creation, so ShopifyStore's before_save
  # callback stamps packing_enabled_at to (roughly) now. Push it into the
  # past so the happy-path orders below (ordered_at: 1.day.ago via the
  # order factory, or explicitly "now") are unambiguously at/after it and
  # the no-backfill guard in PackageAutoBuilder#eligible? doesn't reject them.
  let(:store) do
    create(:shopify_store, packing_enabled: true, package_prefix: "XMBDE", package_number_start: 2013094).tap do |s|
      s.update_columns(packing_enabled_at: 1.year.ago)
    end
  end
  let(:order) do
    o = create(:order, shopify_store: store, financial_status: "paid", ordered_at: Time.current)
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

  it "still refunds an existing package when packing has since been disabled" do
    # Regression for Codex finding 1: the packing_enabled? guard must gate
    # ONLY new-package creation, not the refund of an already-existing
    # package. Build the package while packing is enabled, then disable
    # packing, then fully refund the order — the existing package must
    # still transition to refunded instead of staying stuck active.
    described_class.new(order).call
    pkg = store.packages.find_by(order: order)
    expect(pkg).to be_present

    store.update_columns(packing_enabled: false)
    order.update!(financial_status: "refunded")
    described_class.new(order).call

    expect(pkg.reload).to have_state(:refunded)
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

  it "swallows a mid-build error (a real validation failure) instead of letting it propagate into order sync" do
    # De-mocked (Codex finding 4): instead of stubbing Package#save! to raise,
    # pre-occupy the store's next sequence number with another package so the
    # create! this order's build attempts makes collides with the model's
    # REAL uniqueness validation (number scoped to shopify_store_id) —
    # exercising the outer rescue with a genuine ActiveRecord::RecordInvalid.
    other_order = create(:order, shopify_store: store, financial_status: "paid")
    create(:package, shopify_store: store, order: other_order, number: store.package_number_start)

    expect { described_class.new(order).call }.not_to raise_error
    expect(store.packages.find_by(order: order)).to be_nil
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

    # KEPT MOCKED (Codex finding 4): this exercises the true multi-connection
    # race — a second process's create! reaching the DB in the narrow window
    # AFTER this process's in-lock exists? re-check already returned false but
    # BEFORE it inserts. That interleaving can't be produced deterministically
    # against the real DB from a single connection/thread, and the repo's
    # no-flaky-thread-tests rule rules out simulating it with real concurrency.
    # Stubbing exists? to miss the (real, already-persisted) duplicate is the
    # narrowest way to force the code down the real unique-index rescue path.
    allow(store.packages).to receive(:exists?).with(order_id: order.id).and_return(false)

    builder = described_class.new(order)
    expect { builder.send(:build_package) }.not_to raise_error
    expect(Package.count).to eq(1)
  end

  describe "build-time snapshots" do
    let(:store) { create(:shopify_store, packing_enabled: true, package_prefix: "XMBDE", package_number_start: 2013094) }
    before { store.update_columns(packing_enabled_at: 1.year.ago) }

    let(:variant) { create(:product_variant, customs_name_zh: "積木", customs_name_en: "Blocks", declared_value_usd: 5, hs_code: "9503", import_hs_code: "9503.00", weight_grams: 250) }
    let(:order) do
      o = create(:order, shopify_store: store, financial_status: "paid", ordered_at: Time.current,
                 shopify_data: { "shipping_address" => { "name" => "Jane", "address1" => "1 Main St", "city" => "NYC", "zip" => "10001", "country_code" => "US" } })
      create(:order_line_item, order: o, product_variant: variant, sku_at_sale: "WP-1", title_at_sale: "Puzzle", quantity: 2)
      o
    end

    it "snapshots the order's shipping address onto the package" do
      described_class.new(order).call
      pkg = store.packages.find_by(order: order)
      expect(pkg.shipping_address_snapshot["city"]).to eq("NYC")
      expect(pkg.shipping_address_snapshot["country_code"]).to eq("US")
      expect(pkg.address_overridden).to be(false)
    end

    it "snapshots the variant's customs info onto each package_item" do
      described_class.new(order).call
      item = store.packages.find_by(order: order).package_items.first
      expect(item.customs_name_zh).to eq("積木")
      expect(item.customs_name_en).to eq("Blocks")
      expect(item.declared_value_usd).to eq(5)
      expect(item.hs_code).to eq("9503")
      expect(item.import_hs_code).to eq("9503.00")
      expect(item.customs_weight_grams).to eq(250)
      expect(item.customs_overridden).to be(false)
      expect(item.refunded_quantity).to eq(0)
    end

    it "leaves customs nil when the line item has no product_variant" do
      order.order_line_items.first.update!(product_variant: nil)
      described_class.new(order).call
      item = store.packages.find_by(order: order).package_items.first
      expect(item.customs_name_zh).to be_nil
    end
  end

  describe "no-backfill guard (packing_enabled_at)" do
    # Regression coverage for the finding: enabling packing on an
    # already-synced store must NOT retroactively build packages for orders
    # that were placed before the switch was flipped on. Only orders placed
    # at/after packing_enabled_at are eligible.

    it "does not build a package for an order placed before packing was enabled" do
      old_order = create(:order, shopify_store: store, financial_status: "paid",
                          ordered_at: store.packing_enabled_at - 1.day)

      described_class.new(old_order).call

      expect(store.packages.find_by(order: old_order)).to be_nil
    end

    it "builds a package for an order placed after packing was enabled" do
      new_order = create(:order, shopify_store: store, financial_status: "paid",
                          ordered_at: store.packing_enabled_at + 1.day)

      described_class.new(new_order).call

      expect(store.packages.find_by(order: new_order)).to be_present
    end

    it "still refunds an existing package even when its order predates packing_enabled_at" do
      # Build the package directly (bypassing the builder's eligible? guard,
      # simulating a package that already existed from before this
      # no-backfill guard existed, or was created by another path) for an
      # order older than packing_enabled_at.
      old_order = create(:order, shopify_store: store, financial_status: "paid",
                          ordered_at: store.packing_enabled_at - 30.days)
      pkg = create(:package, shopify_store: store, order: old_order, aasm_state: "pending_review")

      old_order.update!(financial_status: "refunded")
      described_class.new(old_order).call

      expect(pkg.reload).to have_state(:refunded)
    end
  end
end
