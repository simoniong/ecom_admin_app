require "rails_helper"

RSpec.describe "ShippingRemoteAreaVersions", type: :request do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }
  before { sign_in user }

  describe "GET /shipping_remote_area_versions" do
    it "lists versions (owner)" do
      v = create(:shipping_remote_area_version, company: company, country_code: "GB", name: "UK Remote v1")
      create(:shipping_remote_area_rule, version: v, area_label: "area 2")
      get shipping_remote_area_versions_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("UK Remote v1")
    end

    it "filters by country_code" do
      create(:shipping_remote_area_version, company: company, country_code: "GB", name: "GB one")
      create(:shipping_remote_area_version, company: company, country_code: "AU", name: "AU one")
      get shipping_remote_area_versions_path(country_code: "AU")
      expect(response.body).to include("AU one")
      expect(response.body).not_to include("GB one")
    end
  end

  describe "POST /shipping_remote_area_versions" do
    it "creates a version" do
      expect {
        post shipping_remote_area_versions_path, params: {
          shipping_remote_area_version: { country_code: "GB", name: "v1", effective_from: "2026-06-01" }
        }
      }.to change(ShippingRemoteAreaVersion, :count).by(1)
      expect(response).to redirect_to(shipping_remote_area_versions_path)
    end

    it "rejects an invalid version and shows the errors" do
      expect {
        post shipping_remote_area_versions_path, params: {
          shipping_remote_area_version: { country_code: "", name: "", effective_from: "" }
        }
      }.not_to change(ShippingRemoteAreaVersion, :count)
      expect(response).to redirect_to(shipping_remote_area_versions_path)
    end

    it "denies a non-owner member from creating a version" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "shopify_stores" ])
      sign_out user
      sign_in member
      # A member's user factory auto-creates its own (unrelated) owner company,
      # so current_company can't be trusted to default to `company` — select it
      # explicitly rather than relying on companies.first's row order.
      patch switch_company_path(id: company.id)
      post shipping_remote_area_versions_path, params: {
        shipping_remote_area_version: { country_code: "GB", name: "x", effective_from: "2026-06-01" }
      }
      expect(response).to redirect_to(shipping_remote_area_versions_path)
      expect(ShippingRemoteAreaVersion.count).to eq(0)
    end

    it "blocks a member without the shopify_stores permission entirely" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [])
      sign_out user
      sign_in member
      patch switch_company_path(id: company.id)
      post shipping_remote_area_versions_path, params: {
        shipping_remote_area_version: { country_code: "GB", name: "x", effective_from: "2026-06-01" }
      }
      expect(response).to redirect_to(authenticated_root_path)
      expect(ShippingRemoteAreaVersion.count).to eq(0)
    end
  end

  describe "PATCH /shipping_remote_area_versions/:id" do
    it "updates a version for an owner" do
      v = create(:shipping_remote_area_version, company: company, name: "Old name")
      patch shipping_remote_area_version_path(id: v.id), params: {
        shipping_remote_area_version: { name: "New name" }
      }
      expect(response).to redirect_to(shipping_remote_area_versions_path)
      expect(v.reload.name).to eq("New name")
    end

    it "shows validation errors on an invalid update" do
      v = create(:shipping_remote_area_version, company: company)
      patch shipping_remote_area_version_path(id: v.id), params: {
        shipping_remote_area_version: { name: "" }
      }
      expect(response).to redirect_to(shipping_remote_area_versions_path)
      expect(v.reload.name).not_to eq("")
    end
  end

  describe "DELETE /shipping_remote_area_versions/:id" do
    it "destroys a version for an owner" do
      v = create(:shipping_remote_area_version, company: company)
      expect {
        delete shipping_remote_area_version_path(id: v.id)
      }.to change(ShippingRemoteAreaVersion, :count).by(-1)
      expect(response).to redirect_to(shipping_remote_area_versions_path)
    end
  end

  describe "rules" do
    let!(:version) { create(:shipping_remote_area_version, company: company, country_code: "GB") }

    it "creates a rule directly" do
      expect {
        post shipping_remote_area_version_rules_path(shipping_remote_area_version_id: version.id), params: {
          shipping_remote_area_rule: { postal_start: "AB35", postal_end: "AB35", surcharge_cny: 10, area_label: "area 3" }
        }
      }.to change(version.rules, :count).by(1)
      expect(response).to redirect_to(shipping_remote_area_versions_path)
    end

    it "rejects an invalid rule" do
      expect {
        post shipping_remote_area_version_rules_path(shipping_remote_area_version_id: version.id), params: {
          shipping_remote_area_rule: { postal_start: "", postal_end: "", surcharge_cny: "" }
        }
      }.not_to change(version.rules, :count)
      expect(response).to redirect_to(shipping_remote_area_versions_path)
    end

    it "destroys a rule" do
      rule = create(:shipping_remote_area_rule, version: version)
      expect {
        delete shipping_remote_area_version_rule_path(shipping_remote_area_version_id: version.id, id: rule.id)
      }.to change(version.rules, :count).by(-1)
      expect(response).to redirect_to(shipping_remote_area_versions_path)
    end

    it "batch-imports rules into a version, replacing any existing rules" do
      # Seed a pre-existing rule so we can prove the import replaces rather than
      # appends: 1 existing + 2 imported must end at 2, not 3.
      create(:shipping_remote_area_rule, version: version, postal_start: "ZZ00", postal_end: "ZZ99")
      post import_shipping_remote_area_version_rules_path(shipping_remote_area_version_id: version.id),
           params: { text: "AB35, area 3, 10\nIV, area 2, 17" }
      expect(version.reload.rules.count).to eq(2)
      expect(version.rules.pluck(:postal_start)).not_to include("ZZ00")
      expect(response).to redirect_to(shipping_remote_area_versions_path)
    end

    it "shows errors from a failed batch import" do
      post import_shipping_remote_area_version_rules_path(shipping_remote_area_version_id: version.id),
           params: { text: "@@@, area 3, 10" }
      expect(version.reload.rules.count).to eq(0)
      expect(response).to redirect_to(shipping_remote_area_versions_path)
    end

    it "denies rule creation to a non-owner member" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "shopify_stores" ])
      sign_out user
      sign_in member
      patch switch_company_path(id: company.id)
      expect {
        post shipping_remote_area_version_rules_path(shipping_remote_area_version_id: version.id), params: {
          shipping_remote_area_rule: { postal_start: "AB35", postal_end: "AB35", surcharge_cny: 10 }
        }
      }.not_to change(version.rules, :count)
      expect(response).to redirect_to(shipping_remote_area_versions_path)
    end
  end
end
