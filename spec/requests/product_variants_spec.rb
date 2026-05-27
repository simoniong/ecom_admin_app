require "rails_helper"

RSpec.describe "ProductVariants", type: :request do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first) }
  let(:product) { create(:product, shopify_store: store) }
  let!(:variant) { create(:product_variant, product: product) }

  before { sign_in user }

  describe "PATCH /product_variants/:id" do
    it "updates unit_cost" do
      patch product_variant_path(id: variant.id), params: { product_variant: { unit_cost: "12.50" } }
      expect(variant.reload.unit_cost).to eq(12.50)
    end

    it "updates weight_grams" do
      patch product_variant_path(id: variant.id), params: { product_variant: { weight_grams: "250.5" } }
      expect(variant.reload.weight_grams).to eq(250.5)
    end

    it "rejects negative unit_cost" do
      patch product_variant_path(id: variant.id), params: { product_variant: { unit_cost: "-1" } }
      expect(variant.reload.unit_cost).to be_nil
    end

    it "does not update a cross-company variant" do
      other_store = create(:shopify_store)
      other_product = create(:product, shopify_store: other_store)
      other_variant = create(:product_variant, product: other_product, unit_cost: nil)

      begin
        patch product_variant_path(id: other_variant.id), params: { product_variant: { unit_cost: "5" } }
      rescue ActiveRecord::RecordNotFound
        # Acceptable: scoped finder raised before action ran
      end

      expect(other_variant.reload.unit_cost).to be_nil
    end
  end
end
