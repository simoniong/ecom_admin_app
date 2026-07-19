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

    it "updates packaging_cost" do
      patch product_variant_path(id: variant.id), params: { product_variant: { packaging_cost: "2.75" } }
      expect(variant.reload.packaging_cost).to eq(2.75)
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

  describe "PATCH /product_variants/:id (customs, context=customs)" do
    it "saves all four required customs fields together" do
      patch product_variant_path(id: variant.id, context: "customs"),
            params: { product_variant: {
              customs_name_zh: "積木", customs_name_en: "Blocks",
              declared_value_usd: "9.99", weight_grams: "120"
            } }
      variant.reload
      expect(variant.customs_name_zh).to eq("積木")
      expect(variant.customs_name_en).to eq("Blocks")
      expect(variant.declared_value_usd).to eq(9.99)
      expect(variant.weight_grams).to eq(120)
    end

    it "rejects (enforce-required) when a customs edit leaves a required field blank, saving nothing" do
      patch product_variant_path(id: variant.id, context: "customs"),
            params: { product_variant: {
              customs_name_zh: "積木", customs_name_en: "",
              declared_value_usd: "9.99", weight_grams: "120"
            } }
      variant.reload
      expect(variant.customs_name_zh).to be_nil
      expect(variant.customs_name_en).to be_nil
      expect(variant.declared_value_usd).to be_nil
    end

    it "does not enforce the :customs context when only weight_grams (shared with the cost page) is submitted" do
      patch product_variant_path(id: variant.id, context: "customs"),
            params: { product_variant: { weight_grams: "75" } }
      variant.reload
      expect(variant.weight_grams).to eq(75)
      expect(variant.customs_name_zh).to be_nil # still incomplete, but the lone weight edit was not rejected
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

    it "updates packaging_cost across selected variants" do
      post bulk_update_product_variants_path,
           params: { variant_ids: [ variant.id, variant2.id ], packaging_cost: "1.20" }
      expect(variant.reload.packaging_cost).to eq(1.20)
      expect(variant2.reload.packaging_cost).to eq(1.20)
    end

    it "treats packaging_cost alone as a provided field (not bulk_no_fields)" do
      post bulk_update_product_variants_path,
           params: { variant_ids: [ variant.id ], packaging_cost: "0.50" }
      expect(variant.reload.packaging_cost).to eq(0.50)
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

    it "regression: does not enforce the :customs context even though customs fields are blank" do
      expect(variant.customs_name_zh).to be_nil
      post bulk_update_product_variants_path,
           params: { variant_ids: [ variant.id ], unit_cost: "3.00" }
      expect(variant.reload.unit_cost).to eq(3.00)
    end
  end

  describe "POST /product_variants/bulk_update_customs" do
    let!(:variant2) { create(:product_variant, product: product) }

    it "updates customs fields across selected variants when all required fields are present" do
      post bulk_update_customs_product_variants_path,
           params: { variant_ids: [ variant.id, variant2.id ],
                     customs_name_zh: "積木", customs_name_en: "Blocks",
                     declared_value_usd: "5.00", weight_grams: "80" }

      [ variant, variant2 ].each do |v|
        v.reload
        expect(v.customs_name_zh).to eq("積木")
        expect(v.customs_name_en).to eq("Blocks")
        expect(v.declared_value_usd).to eq(5.00)
        expect(v.weight_grams).to eq(80)
      end
    end

    it "rejects (enforce-required) the whole batch when a selected variant would be left with a blank required field" do
      # variant has no customs info yet; setting only declared_value_usd leaves
      # customs_name_zh/en and weight_grams blank -> invalid on :customs.
      post bulk_update_customs_product_variants_path,
           params: { variant_ids: [ variant.id ], declared_value_usd: "5.00" }

      variant.reload
      expect(variant.declared_value_usd).to be_nil
      follow_redirect!
      expect(response.body).to include("can&#39;t be blank")
    end

    it "rolls back the whole transaction — an already-complete variant in the same batch is not saved either" do
      variant2.update!(customs_name_zh: "A", customs_name_en: "B", declared_value_usd: 1, weight_grams: 50)

      post bulk_update_customs_product_variants_path,
           params: { variant_ids: [ variant.id, variant2.id ], hs_code: "1234.56" }

      expect(variant.reload.hs_code).to be_nil
      expect(variant2.reload.hs_code).to be_nil
    end

    it "alerts when no ids selected" do
      post bulk_update_customs_product_variants_path, params: { customs_name_zh: "A" }
      follow_redirect!
      expect(response.body).to include(I18n.t("product_variants.bulk_no_selection"))
    end

    it "alerts when no customs fields provided" do
      post bulk_update_customs_product_variants_path, params: { variant_ids: [ variant.id ] }
      follow_redirect!
      expect(response.body).to include(I18n.t("product_variants.bulk_no_fields_customs"))
    end

    it "silently skips ids belonging to other companies" do
      other_store = create(:shopify_store)
      other_product = create(:product, shopify_store: other_store)
      other_variant = create(:product_variant, product: other_product)

      post bulk_update_customs_product_variants_path,
           params: { variant_ids: [ variant.id, other_variant.id ],
                     customs_name_zh: "積木", customs_name_en: "Blocks",
                     declared_value_usd: "5.00", weight_grams: "80" }

      expect(variant.reload.customs_name_zh).to eq("積木")
      expect(other_variant.reload.customs_name_zh).to be_nil
    end
  end

  describe "customs permission gate" do
    let(:owner) { create(:user) }
    let(:company) { owner.companies.first }
    let!(:gate_store) { create(:shopify_store, company: company, user: owner) }
    let!(:gate_product) { create(:product, shopify_store: gate_store) }
    let!(:gate_variant) { create(:product_variant, product: gate_product) }

    before { sign_out user }

    it "allows a member granted the products permission to bulk-update customs" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "products" ])
      sign_in member
      patch switch_company_path(id: company.id)

      post bulk_update_customs_product_variants_path,
           params: { variant_ids: [ gate_variant.id ], customs_name_zh: "A", customs_name_en: "B",
                     declared_value_usd: "1", weight_grams: "10" }

      expect(response).not_to redirect_to(authenticated_root_path)
      expect(gate_variant.reload.customs_name_zh).to eq("A")
    end

    it "denies a member without the products permission (redirect, nothing saved)" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "shopify_stores" ])
      sign_in member
      patch switch_company_path(id: company.id)

      post bulk_update_customs_product_variants_path,
           params: { variant_ids: [ gate_variant.id ], customs_name_zh: "A" }

      expect(response).to redirect_to(authenticated_root_path)
      expect(gate_variant.reload.customs_name_zh).to be_nil
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
