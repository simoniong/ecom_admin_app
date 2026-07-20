require "rails_helper"

RSpec.describe ProductVariant, type: :model do
  describe "associations" do
    it "belongs to a product" do
      variant = create(:product_variant)
      expect(variant.product).to be_a(Product)
    end

    it "exposes shopify_store through product" do
      variant = create(:product_variant)
      expect(variant.shopify_store).to eq(variant.product.shopify_store)
    end

    it "has many order_line_items" do
      expect(ProductVariant.reflect_on_association(:order_line_items).macro).to eq(:has_many)
      expect(ProductVariant.reflect_on_association(:order_line_items).options[:dependent]).to eq(:nullify)
    end
  end

  describe "validations" do
    it "is invalid without a shopify_variant_id" do
      v = build(:product_variant, shopify_variant_id: nil)
      expect(v).not_to be_valid
      expect(v.errors[:shopify_variant_id]).to include("can't be blank")
    end

    it "accepts unit_cost = 0" do
      v = build(:product_variant, unit_cost: 0)
      expect(v).to be_valid
    end

    it "rejects negative unit_cost" do
      v = build(:product_variant, unit_cost: -0.01)
      expect(v).not_to be_valid
    end

    it "accepts nil unit_cost" do
      v = build(:product_variant, unit_cost: nil)
      expect(v).to be_valid
    end

    it "rejects weight_grams = 0" do
      v = build(:product_variant, weight_grams: 0)
      expect(v).not_to be_valid
    end

    it "accepts weight_grams > 0" do
      v = build(:product_variant, weight_grams: 250.5)
      expect(v).to be_valid
    end

    it "accepts nil weight_grams" do
      v = build(:product_variant, weight_grams: nil)
      expect(v).to be_valid
    end

    it "defaults packaging_cost to 0" do
      v = create(:product_variant)
      expect(v.packaging_cost).to eq(0)
    end

    it "accepts packaging_cost = 0" do
      v = build(:product_variant, packaging_cost: 0)
      expect(v).to be_valid
    end

    it "accepts a positive packaging_cost" do
      v = build(:product_variant, packaging_cost: 3.50)
      expect(v).to be_valid
    end

    it "rejects negative packaging_cost" do
      v = build(:product_variant, packaging_cost: -0.01)
      expect(v).not_to be_valid
    end
  end

  describe "customs info" do
    it "is complete only when zh name, en name, declared value and weight are all present" do
      v = build(:product_variant, customs_name_zh: "積木", customs_name_en: "Blocks",
                declared_value_usd: 5, weight_grams: 100)
      expect(v.customs_complete?).to be(true)
    end

    it "is incomplete when any required customs field is blank" do
      v = build(:product_variant, customs_name_zh: "積木", customs_name_en: "Blocks",
                declared_value_usd: nil, weight_grams: 100)
      expect(v.customs_complete?).to be(false)
    end

    it "on the :customs context, requires all four fields together" do
      v = build(:product_variant, customs_name_zh: "積木", customs_name_en: nil,
                declared_value_usd: 5, weight_grams: 100)
      expect(v.valid?(:customs)).to be(false)
      expect(v.errors[:customs_name_en]).to be_present
    end

    it "on the default context, does NOT require customs fields (Shopify sync creates blanks)" do
      v = build(:product_variant, customs_name_zh: nil, customs_name_en: nil, declared_value_usd: nil)
      v.valid?
      expect(v.errors[:customs_name_en]).to be_empty
    end
  end

  describe "uniqueness of shopify_variant_id within a product" do
    it "rejects duplicates via DB index" do
      existing = create(:product_variant)
      expect {
        create(:product_variant, product: existing.product, shopify_variant_id: existing.shopify_variant_id)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
