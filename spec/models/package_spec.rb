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
end
