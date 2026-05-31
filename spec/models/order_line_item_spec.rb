require "rails_helper"

RSpec.describe OrderLineItem, type: :model do
  describe "associations" do
    it "belongs to an order" do
      li = create(:order_line_item)
      expect(li.order).to be_a(Order)
    end

    it "product_variant is optional" do
      li = build(:order_line_item, product_variant: nil)
      expect(li).to be_valid
    end

    it "can belong to a product_variant" do
      variant = create(:product_variant)
      li = create(:order_line_item, product_variant: variant)
      expect(li.product_variant).to eq(variant)
    end
  end

  describe "validations" do
    it "is invalid without a shopify_line_item_id" do
      li = build(:order_line_item, shopify_line_item_id: nil)
      expect(li).not_to be_valid
      expect(li.errors[:shopify_line_item_id]).to include("can't be blank")
    end

    it "is invalid with zero quantity" do
      li = build(:order_line_item, quantity: 0)
      expect(li).not_to be_valid
    end

    it "is invalid with negative quantity" do
      li = build(:order_line_item, quantity: -1)
      expect(li).not_to be_valid
    end

    it "is invalid without quantity" do
      li = build(:order_line_item, quantity: nil)
      expect(li).not_to be_valid
    end
  end

  describe "uniqueness within an order" do
    it "rejects duplicate shopify_line_item_id within the same order via DB index" do
      existing = create(:order_line_item)
      expect {
        create(:order_line_item, order: existing.order, shopify_line_item_id: existing.shopify_line_item_id)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
