require "rails_helper"

RSpec.describe "ShippingRateCardRates", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let(:member_user) { create(:user) }
  let!(:member_membership) do
    create(:membership, company: company, user: member_user, role: :member, permissions: %w[shopify_stores])
  end
  let!(:version) { create(:shipping_rate_card_version, company: company) }

  let(:valid_attrs) { { weight_min_kg: "0.05", weight_max_kg: "0.2", per_kg_rate_cny: "92.0", flat_fee_cny: "25.0" } }

  describe "POST .../rates" do
    it "creates a rate for an owner" do
      sign_in owner
      expect {
        post shipping_rate_card_version_rates_path(shipping_rate_card_version_id: version.id),
             params: { shipping_rate_card_rate: valid_attrs }
      }.to change(version.rates, :count).by(1)
      expect(response).to redirect_to(shipping_rate_card_versions_path)
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      expect {
        post shipping_rate_card_version_rates_path(shipping_rate_card_version_id: version.id),
             params: { shipping_rate_card_rate: valid_attrs }
      }.not_to change(ShippingRateCardRate, :count)
    end
  end

  describe "PATCH .../rates/:id" do
    let!(:rate) { create(:shipping_rate_card_rate, version: version, per_kg_rate_cny: 92.0) }

    it "updates and renders Turbo Stream for an owner" do
      sign_in owner
      patch shipping_rate_card_version_rate_path(shipping_rate_card_version_id: version.id, id: rate.id),
            params: { shipping_rate_card_rate: { per_kg_rate_cny: "100.0" } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response.media_type).to include("turbo-stream")
      expect(rate.reload.per_kg_rate_cny).to eq(100.0)
    end
  end

  describe "DELETE .../rates/:id" do
    let!(:rate) { create(:shipping_rate_card_rate, version: version) }

    it "destroys for an owner" do
      sign_in owner
      expect {
        delete shipping_rate_card_version_rate_path(shipping_rate_card_version_id: version.id, id: rate.id)
      }.to change(ShippingRateCardRate, :count).by(-1)
    end
  end

  describe "POST .../rates/import" do
    let!(:version) { create(:shipping_rate_card_version, company: company) }

    it "bulk-imports rates for an owner (replace)" do
      create(:shipping_rate_card_rate, version: version)  # wiped
      sign_in owner
      post import_shipping_rate_card_version_rates_path(shipping_rate_card_version_id: version.id),
           params: { text: "1,0,0.25,27,23\n2,0,0.25,27,31" }
      expect(version.rates.reload.count).to eq(2)
      expect(response).to redirect_to(shipping_rate_card_versions_path)
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      post import_shipping_rate_card_version_rates_path(shipping_rate_card_version_id: version.id),
           params: { text: "1,0,0.25,27,23" }
      expect(version.rates.reload.count).to eq(0)
    end

    it "reports errors and changes nothing on bad input" do
      create(:shipping_rate_card_rate, version: version)
      sign_in owner
      post import_shipping_rate_card_version_rates_path(shipping_rate_card_version_id: version.id),
           params: { text: "1,0.3,0.3,27,23" }
      expect(version.rates.reload.count).to eq(1)  # unchanged
    end
  end

  describe "cross-company isolation" do
    it "404s when the version belongs to another company" do
      other_version = create(:shipping_rate_card_version)
      other_rate = create(:shipping_rate_card_rate, version: other_version)
      sign_in owner
      patch shipping_rate_card_version_rate_path(shipping_rate_card_version_id: other_version.id, id: other_rate.id),
            params: { shipping_rate_card_rate: { per_kg_rate_cny: "1" } }
      expect(response).to have_http_status(:not_found)
    end
  end
end
