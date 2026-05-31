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

    it "redirects to sign-in (not a Turbo Stream) when unauthenticated" do
      # Guards the JS fix in cell_edit_controller.js: if the session expires
      # mid-edit, the server must redirect to login instead of returning a
      # 200 Turbo Stream, so the controller can detect it and navigate away
      # rather than silently swallowing the failed save.
      sign_out user
      patch product_variant_path(id: variant.id),
            params: { product_variant: { unit_cost: "5" } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to redirect_to(new_user_session_path)
      expect(response.media_type).not_to include("turbo-stream")
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

  describe "POST /product_variants/bulk_update" do
    let!(:variant2) { create(:product_variant, product: product) }

    it "updates unit_cost across selected variants" do
      post bulk_update_product_variants_path,
           params: { variant_ids: [ variant.id, variant2.id ], unit_cost: "5.50" }
      expect(variant.reload.unit_cost).to eq(5.50)
      expect(variant2.reload.unit_cost).to eq(5.50)
    end

    it "updates only weight_grams when only that is sent" do
      post bulk_update_product_variants_path,
           params: { variant_ids: [ variant.id ], weight_grams: "300" }
      expect(variant.reload.weight_grams).to eq(300)
      expect(variant.unit_cost).to be_nil
    end

    it "alerts when no ids selected" do
      post bulk_update_product_variants_path, params: { unit_cost: "5" }
      follow_redirect!
      expect(response.body).to include(I18n.t("product_variants.bulk_no_selection"))
    end

    it "alerts when no fields provided" do
      post bulk_update_product_variants_path, params: { variant_ids: [ variant.id ] }
      follow_redirect!
      expect(response.body).to include(I18n.t("product_variants.bulk_no_fields"))
    end

    it "silently skips ids belonging to other companies" do
      other_store = create(:shopify_store)
      other_product = create(:product, shopify_store: other_store)
      other_variant = create(:product_variant, product: other_product, unit_cost: nil)

      post bulk_update_product_variants_path,
           params: { variant_ids: [ variant.id, other_variant.id ], unit_cost: "9.99" }

      expect(variant.reload.unit_cost).to eq(9.99)
      expect(other_variant.reload.unit_cost).to be_nil
    end
  end

  describe "GET /product_variants/matching_ids" do
    it "returns ids of variants matching search, scoped to store" do
      create(:product_variant, product: product, sku: "OTHER-1")
      get matching_ids_product_variants_path, params: { store_id: store.id, search: variant.sku }
      body = JSON.parse(response.body)
      expect(body["ids"]).to include(variant.id)
      expect(body["ids"].length).to eq(1)
    end

    it "returns [] when store_id is not visible" do
      other_store = create(:shopify_store)
      get matching_ids_product_variants_path, params: { store_id: other_store.id }
      body = JSON.parse(response.body)
      expect(body["ids"]).to eq([])
    end
  end
end
