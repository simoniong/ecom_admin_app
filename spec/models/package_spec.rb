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
    end

    it "can refund from any active state including shipped, and refund is terminal" do
      pkg.submit_review!; pkg.apply_tracking!; pkg.to_label!; pkg.ship!
      pkg.refund!
      expect(pkg).to have_state(:refunded)
      expect(pkg).not_to allow_event(:submit_review)
    end

    it "can back_to_process from applying_tracking" do
      pkg.submit_review!; pkg.apply_tracking!
      pkg.back_to_process!
      expect(pkg).to have_state(:pending_process)
    end
  end
end
