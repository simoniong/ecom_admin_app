require "rails_helper"

RSpec.describe "ShippingRateCardVersions", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let(:member_user) { create(:user) }
  let!(:member_membership) do
    create(:membership, company: company, user: member_user, role: :member, permissions: %w[shopify_stores])
  end

  let(:valid_attrs) do
    { name: "Q2 2026 US Battery", country_code: "US", service_type: "standard_with_battery",
      effective_from: "2026-04-01", effective_to: "" }
  end

  describe "GET /shipping_rate_card_versions" do
    before { sign_in owner }

    it "returns 200 and lists versions with rates" do
      version = create(:shipping_rate_card_version, company: company, name: "Q1 US")
      create(:shipping_rate_card_rate, version: version)
      get shipping_rate_card_versions_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Q1 US")
    end

    it "filters by country_code" do
      create(:shipping_rate_card_version, company: company, name: "US one", country_code: "US")
      create(:shipping_rate_card_version, company: company, name: "CA one", country_code: "CA")
      get shipping_rate_card_versions_path(country_code: "CA")
      expect(response.body).to include("CA one")
      expect(response.body).not_to include("US one")
    end
  end

  describe "POST /shipping_rate_card_versions" do
    it "creates a version for an owner" do
      sign_in owner
      expect {
        post shipping_rate_card_versions_path, params: { shipping_rate_card_version: valid_attrs }
      }.to change(ShippingRateCardVersion, :count).by(1)
      expect(response).to redirect_to(shipping_rate_card_versions_path)
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      expect {
        post shipping_rate_card_versions_path, params: { shipping_rate_card_version: valid_attrs }
      }.not_to change(ShippingRateCardVersion, :count)
      expect(response).to redirect_to(shipping_rate_card_versions_path)
    end
  end

  describe "PATCH /shipping_rate_card_versions/:id" do
    let!(:version) { create(:shipping_rate_card_version, company: company, name: "Old name") }

    it "updates a field and renders a Turbo Stream for an owner" do
      sign_in owner
      patch shipping_rate_card_version_path(id: version.id),
            params: { shipping_rate_card_version: { name: "New name" } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response.media_type).to include("turbo-stream")
      expect(version.reload.name).to eq("New name")
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      patch shipping_rate_card_version_path(id: version.id),
            params: { shipping_rate_card_version: { name: "Hacked" } }
      expect(version.reload.name).to eq("Old name")
    end
  end

  describe "DELETE /shipping_rate_card_versions/:id" do
    let!(:version) { create(:shipping_rate_card_version, company: company) }

    it "destroys for an owner and cascades to rates" do
      create(:shipping_rate_card_rate, version: version)
      sign_in owner
      expect {
        delete shipping_rate_card_version_path(id: version.id)
      }.to change(ShippingRateCardVersion, :count).by(-1).and change(ShippingRateCardRate, :count).by(-1)
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      expect {
        delete shipping_rate_card_version_path(id: version.id)
      }.not_to change(ShippingRateCardVersion, :count)
    end
  end

  describe "cross-company isolation" do
    it "404s on another company's version" do
      other_version = create(:shipping_rate_card_version) # different company
      sign_in owner
      patch shipping_rate_card_version_path(id: other_version.id),
            params: { shipping_rate_card_version: { name: "x" } }
      expect(response).to have_http_status(:not_found)
    end
  end
end
