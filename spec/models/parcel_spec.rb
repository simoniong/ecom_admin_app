require "rails_helper"

RSpec.describe Parcel, type: :model do
  let(:user)  { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let(:order) { create(:order, customer: customer, shopify_store: store, estimated_shipping_cost: 10) }

  describe "rollup to orders.actual_shipping_cost" do
    it "sums parcel cost_amount into the order after create" do
      create(:parcel, shopify_store: store, order: order, cost_amount: 12.34)
      create(:parcel, shopify_store: store, order: order, cost_amount: 5.66)

      expect(order.reload.actual_shipping_cost).to eq(18.00)
    end

    it "recalculates after update" do
      parcel = create(:parcel, shopify_store: store, order: order, cost_amount: 12.34)
      parcel.update!(cost_amount: 20)

      expect(order.reload.actual_shipping_cost).to eq(20)
    end

    it "resets to nil (not zero) when the last parcel is destroyed" do
      parcel = create(:parcel, shopify_store: store, order: order, cost_amount: 12.34)
      parcel.destroy!

      expect(order.reload.actual_shipping_cost).to be_nil
    end

    it "recalculates BOTH orders when a parcel moves between them" do
      other = create(:order, customer: customer, shopify_store: store)
      parcel = create(:parcel, shopify_store: store, order: order, cost_amount: 9)
      expect(order.reload.actual_shipping_cost).to eq(9)

      parcel.update!(order: other)

      expect(order.reload.actual_shipping_cost).to be_nil
      expect(other.reload.actual_shipping_cost).to eq(9)
    end

    it "recalculates the order when an unmatched parcel is assigned to it" do
      parcel = create(:parcel, shopify_store: store, order: nil, cost_amount: 7)
      parcel.update!(order: order)

      expect(order.reload.actual_shipping_cost).to eq(7)
    end
  end

  describe "validations" do
    it "requires identifier to be unique per store" do
      create(:parcel, shopify_store: store, identifier: "XMBDE2012381")
      dup = build(:parcel, shopify_store: store, identifier: "XMBDE2012381")

      expect(dup).not_to be_valid
      expect(dup.errors[:identifier]).to be_present
    end

    it "allows the same identifier in a different store" do
      other_store = create(:shopify_store, user: user, company: user.companies.first)
      create(:parcel, shopify_store: store, identifier: "XMBDE2012381")

      expect(build(:parcel, shopify_store: other_store, identifier: "XMBDE2012381")).to be_valid
    end

    it "requires identifier" do
      expect(build(:parcel, shopify_store: store, identifier: nil)).not_to be_valid
    end
  end
end
