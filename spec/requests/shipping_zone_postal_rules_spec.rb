require "rails_helper"

RSpec.describe "ShippingZonePostalRules", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let(:member_user) { create(:user) }
  let!(:member_membership) do
    create(:membership, company: company, user: member_user, role: :member, permissions: %w[shopify_stores])
  end

  describe "GET /shipping_zone_postal_rules" do
    it "renders for a member with shopify_stores permission" do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1")
      sign_in member_user
      patch switch_company_path(id: company.id)
      get shipping_zone_postal_rules_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET index shows existing map editable" do
    it "pre-fills the textarea with the current map" do
      PostalZoneImporter.new(company: company, country: "AU", text: "1: 2000-2079, 2158").call
      sign_in owner
      get shipping_zone_postal_rules_path
      expect(response.body).to include("1: 2000-2079, 2158")
    end
  end

  describe "POST /shipping_zone_postal_rules/import" do
    it "imports for an owner and replaces the country's map" do
      sign_in owner
      expect {
        post import_shipping_zone_postal_rules_path,
             params: { country_code: "AU", text: "1: 2000-2079\n2: 2080-2084" }
      }.to change { company.shipping_zone_postal_rules.where(country_code: "AU").count }.from(0).to(2)
      expect(response).to redirect_to(shipping_zone_postal_rules_path)
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      expect {
        post import_shipping_zone_postal_rules_path, params: { country_code: "AU", text: "1: 2000-2079" }
      }.not_to change(ShippingZonePostalRule, :count)
    end

    it "reports errors and saves nothing on bad input" do
      sign_in owner
      post import_shipping_zone_postal_rules_path, params: { country_code: "AU", text: "1: oops" }
      expect(company.shipping_zone_postal_rules.count).to eq(0)
      follow_redirect!
      expect(response.body).to include(I18n.t("shipping_zone_postal_rules.errors_title"))
    end
  end
end
