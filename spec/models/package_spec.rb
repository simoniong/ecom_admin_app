require "rails_helper"
RSpec.describe Package do
  it "builds a package_code from the store prefix and a 7-digit number" do
    store = create(:shopify_store, package_prefix: "XMBDE", package_number_start: 1)
    pkg = create(:package, shopify_store: store, number: 2013094)
    expect(pkg.package_code).to eq("XMBDE2013094")
  end

  it "pads numbers shorter than 7 digits" do
    store = create(:shopify_store, package_prefix: "AB")
    pkg = create(:package, shopify_store: store, number: 42)
    expect(pkg.package_code).to eq("AB0000042")
  end

  it "enforces unique number per store" do
    store = create(:shopify_store)
    create(:package, shopify_store: store, number: 5)
    dup = build(:package, shopify_store: store, number: 5)
    expect(dup).not_to be_valid
  end

  describe "snapshot fields" do
    it "defaults shipping_address_snapshot to {} and address_overridden to false" do
      pkg = create(:package)
      expect(pkg.shipping_address_snapshot).to eq({})
      expect(pkg.address_overridden).to be(false)
    end
  end

  describe "application_status" do
    it "accepts each valid value" do
      %w[none pending succeeded failed].each do |status|
        pkg = build(:package, application_status: status)
        expect(pkg).to be_valid
      end
    end

    it "rejects a bogus value" do
      pkg = build(:package, application_status: "bogus")
      expect(pkg).not_to be_valid
      expect(pkg.errors[:application_status]).to be_present
    end
  end

  describe "state machine" do
    let(:pkg) { create(:package) }

    it "starts in pending_review" do
      expect(pkg).to have_state(:pending_review)  # aasm rspec matcher
    end

    it "walks the happy path review→process→applying→label→shipped" do
      pkg.submit_review!
      expect(pkg).to have_state(:pending_process)
      pkg.apply_tracking!
      expect(pkg).to have_state(:applying_tracking)
      pkg.to_label!
      expect(pkg).to have_state(:pending_label)
      pkg.ship!
      expect(pkg).to have_state(:shipped)
    end

    it "rejects skipping states" do
      expect(pkg).not_to allow_event(:ship)
      expect { pkg.ship! }.to raise_error(AASM::InvalidTransition)
    end

    it "records held_from on hold and restores it on unhold" do
      pkg.submit_review!  # now pending_process
      pkg.hold!
      expect(pkg).to have_state(:held)
      expect(pkg.held_from).to eq("pending_process")
      pkg.unhold!
      expect(pkg).to have_state(:pending_process)
      expect(pkg.held_from).to be_nil
      expect(pkg.reload.held_from).to be_nil  # persisted, not just in-memory
    end

    it "can refund from any active state including shipped, and refund is terminal" do
      pkg.submit_review!; pkg.apply_tracking!; pkg.to_label!; pkg.ship!
      pkg.refund!
      expect(pkg).to have_state(:refunded)
      expect(pkg).not_to allow_event(:submit_review)
    end

    it "can refund from held" do
      pkg.submit_review!
      pkg.hold!
      expect(pkg).to have_state(:held)
      pkg.refund!
      expect(pkg).to have_state(:refunded)
    end

    it "can back_to_process from applying_tracking" do
      pkg.submit_review!; pkg.apply_tracking!
      pkg.back_to_process!
      expect(pkg).to have_state(:pending_process)
    end

    it "can back_to_review from pending_process" do
      pkg.submit_review!
      pkg.back_to_review!
      expect(pkg).to have_state(:pending_review)
    end

    it "raises rather than misrouting when unhold has no matching held_from" do
      pkg.submit_review!
      pkg.hold!
      pkg.update_columns(held_from: nil) # corrupt the origin so no guard matches
      expect { pkg.unhold! }.to raise_error(AASM::InvalidTransition)
      expect(pkg.reload).to have_state(:held)
    end
  end

  describe "tracking readiness" do
    let(:store) { create(:shopify_store, package_prefix: "XM", package_number_start: 1) }
    let(:order) { create(:order, shopify_store: store, financial_status: "paid") }
    let(:channel) { create(:logistics_channel) }

    def complete_package
      pkg = create(:package, shopify_store: store, order: order, aasm_state: "pending_process", number: 1,
                   logistics_channel: channel,
                   shipping_address_snapshot: { "name" => "J", "country_code" => "US", "address1" => "1 St", "city" => "NYC" })
      create(:package_item, package: pkg, sku: "A", quantity: 2, refunded_quantity: 0,
             customs_name_zh: "積木", customs_name_en: "Blocks", declared_value_usd: 5, customs_weight_grams: 100)
      pkg
    end

    it "is ready when address, logistics and customs are all complete" do
      expect(complete_package.ready_for_tracking?).to be(true)
    end

    it "reports a blocker when logistics is unassigned" do
      pkg = complete_package
      pkg.update!(logistics_channel: nil)
      expect(pkg.ready_for_tracking?).to be(false)
      expect(pkg.tracking_blockers.join).to match(/logistic/i).or match(/物流/)
    end

    it "reports a blocker when the address is incomplete" do
      pkg = complete_package
      pkg.update!(shipping_address_snapshot: { "name" => "J" })  # missing country/address1/city
      expect(pkg.ready_for_tracking?).to be(false)
      expect(pkg.tracking_blockers).to be_present
    end

    it "reports a blocker for an item missing required customs" do
      pkg = complete_package
      pkg.package_items.first.update!(declared_value_usd: nil)
      expect(pkg.ready_for_tracking?).to be(false)
      expect(pkg.tracking_blockers).to be_present
    end

    it "ignores fully-refunded items in the customs check" do
      pkg = complete_package
      create(:package_item, package: pkg, sku: "B", quantity: 1, refunded_quantity: 1)  # fully refunded, no customs
      expect(pkg.ready_for_tracking?).to be(true)
      expect(pkg.tracking_blockers).to be_empty
    end
  end

  describe "order_cancelled?" do
    let(:store) { create(:shopify_store) }
    it "is true when the order is cancelled and not fully refunded" do
      order = create(:order, shopify_store: store, financial_status: "paid", shopify_data: { "cancelled_at" => "2026-07-20T00:00:00Z" })
      pkg = create(:package, shopify_store: store, order: order, number: 1)
      expect(pkg.order_cancelled?).to be(true)
    end
    it "is false when not cancelled" do
      order = create(:order, shopify_store: store, financial_status: "paid", shopify_data: {})
      expect(create(:package, shopify_store: store, order: order, number: 2).order_cancelled?).to be(false)
    end
    it "is false when fully refunded (that path is 已退款, not cancelled)" do
      order = create(:order, shopify_store: store, financial_status: "refunded", shopify_data: { "cancelled_at" => "2026-07-20T00:00:00Z" })
      expect(create(:package, shopify_store: store, order: order, number: 3).order_cancelled?).to be(false)
    end

    it "does not raise when the order's shopify_data is nil" do
      order = create(:order, shopify_store: store, financial_status: "paid")
      order.update_column(:shopify_data, nil)
      pkg = create(:package, shopify_store: store, order: order, number: 4)
      expect(pkg.order_cancelled?).to be(false)
    end
  end

  describe "#order_packages / #split?" do
    let(:store) { create(:shopify_store) }
    let(:customer) { create(:customer, shopify_store: store) }

    it "reports split? true when the order has more than one package" do
      order = create(:order, customer: customer, shopify_store: store)
      a = create(:package, shopify_store: store, order: order, number: 1)
      create(:package, shopify_store: store, order: order, number: 2)
      expect(a.order_packages.count).to eq(2)
      expect(a.split?).to be(true)
    end

    it "reports split? false for a lone package" do
      order = create(:order, customer: customer, shopify_store: store)
      a = create(:package, shopify_store: store, order: order, number: 1)
      expect(a.split?).to be(false)
    end
  end

  describe "one order → many packages" do
    it "allows two packages to share the same order_id" do
      store = create(:shopify_store)
      order = create(:order, shopify_store: store)
      create(:package, shopify_store: store, order: order, number: 1)
      second = build(:package, shopify_store: store, order: order, number: 2)
      expect(second.save).to be(true)
      expect(store.packages.where(order_id: order.id).count).to eq(2)
    end
  end

  describe "back_to_process clears the tracking-application fields" do
    it "resets application fields when pulled back to pending_process" do
      pkg = create(:package)
      pkg.update!(aasm_state: "applying_tracking", application_status: "succeeded",
                  raydo_order_id: "R123", tracking_number: "TN999", carrier: "DHL",
                  application_message: "x", applied_at: Time.current)
      pkg.back_to_process!
      pkg.reload
      expect(pkg).to have_state(:pending_process)
      expect(pkg.application_status).to eq("none")
      expect([ pkg.raydo_order_id, pkg.tracking_number, pkg.carrier, pkg.application_message, pkg.applied_at ]).to all(be_nil)
    end
  end

  describe "ship_sync_status" do
    it "defaults to none and validates inclusion" do
      order = create(:order); pkg = create(:package, shopify_store: order.shopify_store, order: order)
      expect(pkg.ship_sync_status).to eq("none")
      pkg.ship_sync_status = "bogus"
      expect(pkg).not_to be_valid
    end
  end
  describe "shopify_fulfillment_id partial unique index" do
    it "rejects a duplicate non-null shopify_fulfillment_id" do
      o1 = create(:order); o2 = create(:order, shopify_store: o1.shopify_store)
      create(:package, shopify_store: o1.shopify_store, order: o1, number: 1, shopify_fulfillment_id: "gid://shopify/Fulfillment/1")
      dup = build(:package, shopify_store: o1.shopify_store, order: o2, number: 2, shopify_fulfillment_id: "gid://shopify/Fulfillment/1")
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
