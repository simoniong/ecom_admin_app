require "rails_helper"

RSpec.describe Fulfillment, type: :model do
  it "is valid with valid attributes" do
    fulfillment = build(:fulfillment)
    expect(fulfillment).to be_valid
  end

  it "requires shopify_fulfillment_id" do
    fulfillment = build(:fulfillment, shopify_fulfillment_id: nil)
    expect(fulfillment).not_to be_valid
  end

  it "enforces shopify_fulfillment_id uniqueness" do
    create(:fulfillment, shopify_fulfillment_id: 77777)
    duplicate = build(:fulfillment, shopify_fulfillment_id: 77777)
    expect(duplicate).not_to be_valid
  end

  it "belongs to order" do
    fulfillment = create(:fulfillment)
    expect(fulfillment.order).to be_a(Order)
  end

  describe ".with_tracking" do
    it "returns fulfillments with tracking numbers" do
      with = create(:fulfillment, tracking_number: "TRACK123")
      create(:fulfillment, tracking_number: nil)
      create(:fulfillment, tracking_number: "")
      expect(Fulfillment.with_tracking).to eq([ with ])
    end
  end
end
