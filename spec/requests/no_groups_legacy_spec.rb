require "rails_helper"

RSpec.describe "Backward compatibility — companies with no Groups", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let(:member) do
    u = create(:user)
    create(:membership, company: company, user: u, role: :member,
           permissions: %w[dashboard orders tickets ad_accounts shopify_stores email_accounts shipments ad_campaigns])
    u
  end

  let!(:store) { create(:shopify_store, company: company, user: owner, shop_domain: "legacy.myshopify.com") }
  let!(:ad) { create(:ad_account, company: company, user: owner, account_id: "act_legacy", account_name: "LegacyAd") }
  let!(:email) { create(:email_account, company: company, user: owner, email: "legacy@example.com") }

  it "has no groups in the company" do
    expect(company.groups).to be_empty
  end

  context "Owner" do
    before { sign_in owner }

    it "sees stores / ad accounts / email accounts" do
      get shopify_stores_path
      expect(response.body).to include("legacy.myshopify.com")
      get ad_accounts_path
      expect(response.body).to include("LegacyAd")
      get email_accounts_path
      expect(response.body).to include("legacy@example.com")
    end

    it "does not show a group selector on the connect forms" do
      get shopify_stores_path
      expect(response.body).not_to include("shopify_stores.group")
      expect(response.body).not_to match(/id="group_id"/i)
    end

    it "can connect a new shopify store without group_id" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SHOPIFY_CLIENT_ID").and_return("test-client-id")

      get shopify_auth_path, params: { shop: "new-store.myshopify.com" }
      expect(response).to have_http_status(:redirect)
      expect(response.location).to include("new-store.myshopify.com/admin/oauth/authorize")
    end

    it "Dashboard hides the group-view switcher" do
      get authenticated_root_path
      expect(response.body).not_to include("group_view_switcher")
    end
  end

  context "Member" do
    before do
      sign_in member
      patch switch_company_path(id: company.id)
    end

    it "sees all company stores / ad accounts / email accounts (legacy behavior)" do
      get shopify_stores_path
      expect(response.body).to include("legacy.myshopify.com")
      get ad_accounts_path
      expect(response.body).to include("LegacyAd")
      get email_accounts_path
      expect(response.body).to include("legacy@example.com")
    end

    it "can view orders scoped to company stores" do
      customer = create(:customer, shopify_store: store)
      create(:order, customer: customer, shopify_store: store, name: "#LEGACY-ORD-001")
      get orders_path
      expect(response.body).to include("LEGACY-ORD-001")
    end
  end
end
