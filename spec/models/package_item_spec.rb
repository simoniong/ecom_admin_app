require "rails_helper"
RSpec.describe PackageItem do
  it "requires a positive integer quantity" do
    expect(build(:package_item, quantity: 0)).not_to be_valid
    expect(build(:package_item, quantity: 2)).to be_valid
  end

  describe "refund tracking" do
    it "defaults refunded_quantity to 0" do
      expect(build(:package_item).refunded_quantity).to eq(0)
    end

    it "is fully_refunded? when refunded_quantity >= quantity" do
      expect(build(:package_item, quantity: 3, refunded_quantity: 3).fully_refunded?).to be(true)
      expect(build(:package_item, quantity: 3, refunded_quantity: 1).fully_refunded?).to be(false)
      expect(build(:package_item, quantity: 3, refunded_quantity: 0).fully_refunded?).to be(false)
    end

    it "rejects a negative refunded_quantity" do
      expect(build(:package_item, refunded_quantity: -1)).not_to be_valid
    end
  end
end
