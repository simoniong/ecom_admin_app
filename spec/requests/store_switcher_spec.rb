require "rails_helper"

RSpec.describe "Store switcher resolution & persistence", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let!(:store_a) { create(:shopify_store, company: company, user: owner) }
  let!(:store_b) { create(:shopify_store, company: company, user: owner) }

  before { sign_in owner }

  describe "Dashboard (All allowed)" do
    it "renders without forcing a store when nothing is selected" do
      get authenticated_root_path
      expect(response).to have_http_status(:success)
      expect(session[:store_id]).to be_nil
    end

    it "persists a selected store id in the session" do
      get authenticated_root_path, params: { store_id: store_a.id }
      expect(session[:store_id]).to eq(store_a.id)
    end

    it "remembers the store across a later page load with no param" do
      get authenticated_root_path, params: { store_id: store_a.id }
      get authenticated_root_path
      expect(session[:store_id]).to eq(store_a.id)
    end

    it "persists the literal 'all' selection" do
      get authenticated_root_path, params: { store_id: store_a.id }
      get authenticated_root_path, params: { store_id: "all" }
      expect(session[:store_id]).to eq("all")
    end
  end

  describe "Orders (All NOT allowed)" do
    it "succeeds and does not overwrite an existing 'all' selection" do
      get authenticated_root_path, params: { store_id: "all" }
      get orders_path
      expect(response).to have_http_status(:success)
      expect(session[:store_id]).to eq("all")
    end

    it "persists a concrete store chosen on Orders" do
      get orders_path, params: { store_id: store_b.id }
      expect(session[:store_id]).to eq(store_b.id)
    end
  end

  describe "Settings pages (no switcher)" do
    it "does not write store_id to the session" do
      get shopify_stores_path, params: { store_id: store_a.id }
      expect(session[:store_id]).to be_nil
    end
  end

  describe "switching company" do
    it "clears the remembered store" do
      get authenticated_root_path, params: { store_id: store_a.id }
      other = create(:company)
      create(:membership, company: other, user: owner, role: :owner)
      patch switch_company_path(id: other.id)
      expect(session[:store_id]).to be_nil
    end
  end
end
