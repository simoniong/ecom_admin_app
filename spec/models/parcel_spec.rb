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

    it "requires cost_amount" do
      parcel = build(:parcel, shopify_store: store, cost_amount: nil)
      expect(parcel).not_to be_valid
      expect(parcel.errors[:cost_amount]).to be_present
    end

    # The DB-level NOT NULL is the real backstop — SUM(cost_amount) silently
    # skips nulls, so a null cost_amount would make money vanish from a
    # rollup while parcels.count still looked right. The model validation
    # alone isn't enough: anything that writes around it (update_column,
    # insert_all, a future bug) must still be stopped at the database.
    it "cannot store a null cost_amount even bypassing the model validation" do
      parcel = build(:parcel, shopify_store: store, cost_amount: nil)
      expect { parcel.save(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it "requires cost_cny" do
      parcel = build(:parcel, shopify_store: store, cost_cny: nil)
      expect(parcel).not_to be_valid
      expect(parcel.errors[:cost_cny]).to be_present
    end

    it "rejects a zero or negative cost_amount" do
      expect(build(:parcel, shopify_store: store, cost_amount: 0)).not_to be_valid
      expect(build(:parcel, shopify_store: store, cost_amount: -13_888.75)).not_to be_valid
    end

    it "rejects a zero or negative cost_cny" do
      expect(build(:parcel, shopify_store: store, cost_cny: 0)).not_to be_valid
      expect(build(:parcel, shopify_store: store, cost_cny: -99_999)).not_to be_valid
    end

    # decimal(10,2) can hold at most 99999999.99. Without an upper bound here,
    # a write past that reaches the database and raises
    # ActiveRecord::RangeError instead of failing validation — every write
    # path rescues that except the HTML inline edit (ParcelsController#update),
    # which 500s. See spec/requests/parcels_spec.rb for that end-to-end case.
    it "rejects a cost_cny at or beyond the decimal(10,2) column's true maximum" do
      expect(build(:parcel, shopify_store: store, cost_cny: 100_000_000)).not_to be_valid
    end

    it "allows the decimal(10,2) column's true maximum cost_cny" do
      parcel = build(:parcel, shopify_store: store,
                              cost_cny: BigDecimal("99999999.99"),
                              cost_amount: BigDecimal("99999999.99"))
      expect(parcel).to be_valid
    end

    # cost_amount is derived from cost_cny / cost_fx_rate: an in-range
    # cost_cny paired with a very low fx_rate (e.g. 0.01) can still overflow
    # cost_amount, so it needs its own independent bound.
    it "rejects a cost_amount at or beyond the decimal(10,2) column's true maximum" do
      expect(build(:parcel, shopify_store: store, cost_amount: 100_000_000)).not_to be_valid
    end
  end
end
