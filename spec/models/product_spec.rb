require "rails_helper"

RSpec.describe Product, type: :model do
  describe "associations" do
    it "belongs to a shopify_store" do
      product = create(:product)
      expect(product.shopify_store).to be_a(ShopifyStore)
    end

    it "has many product_variants" do
      expect(Product.reflect_on_association(:product_variants).macro).to eq(:has_many)
      expect(Product.reflect_on_association(:product_variants).options[:dependent]).to eq(:destroy)
    end
  end

  describe "validations" do
    it "is invalid without a shopify_product_id" do
      product = build(:product, shopify_product_id: nil)
      expect(product).not_to be_valid
      expect(product.errors[:shopify_product_id]).to include("can't be blank")
    end
  end

  describe "uniqueness of shopify_product_id within a store" do
    it "rejects duplicates within the same store via DB index" do
      existing = create(:product)
      expect {
        create(:product, shopify_store: existing.shopify_store, shopify_product_id: existing.shopify_product_id)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same shopify_product_id in different stores" do
      a = create(:product)
      b = create(:product, shopify_product_id: a.shopify_product_id)
      expect(b).to be_persisted
    end
  end
end
