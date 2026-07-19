require "rails_helper"

RSpec.describe "LogisticsAccounts", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }

  before { sign_in owner }

  describe "GET /logistics_account" do
    it "returns success and shows a blank form when no account exists yet" do
      get logistics_account_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("logistics_account_username")
    end

    it "shows the cached customer_id/customer_userid when already authenticated" do
      create(:logistics_account, company: company, customer_id: "6581", customer_userid: "6901")
      get logistics_account_path
      expect(response.body).to include("6581")
      expect(response.body).to include("6901")
    end
  end

  describe "PATCH /logistics_account" do
    it "creates the account on first save (find_or_init)" do
      expect {
        patch logistics_account_path, params: {
          logistics_account: {
            username: "TEST", password: "secret123",
            url1_base: "http://www.sz56t.com:8082", url2_base: "http://www.sz56t.com:8089"
          }
        }
      }.to change(LogisticsAccount, :count).by(1)

      expect(response).to redirect_to(logistics_account_path)
      expect(company.reload.raydo_logistics_account.username).to eq("TEST")
    end

    it "keeps the existing password when the password field is left blank" do
      create(:logistics_account, company: company, username: "TEST", password: "original-secret")

      patch logistics_account_path, params: {
        logistics_account: { username: "TEST-UPDATED", password: "" }
      }

      account = company.reload.raydo_logistics_account
      expect(account.username).to eq("TEST-UPDATED")
      expect(account.password).to eq("original-secret")
    end
  end

  describe "POST /logistics_account/authenticate" do
    it "alerts when credentials are missing instead of calling Raydo" do
      post authenticate_logistics_account_path
      expect(response).to redirect_to(logistics_account_path)
      follow_redirect!
      expect(response.body).to include(I18n.t("logistics_accounts.missing_credentials"))
    end

    it "authenticates via RaydoService and caches the customer ids" do
      account = create(:logistics_account, company: company, username: "TEST", password: "123456",
                        url1_base: "http://raydo.test:8082")
      stub_request(:get, "http://raydo.test:8082/selectAuth.htm")
        .with(query: { username: "TEST", password: "123456" })
        .to_return(body: { customer_id: "6581", customer_userid: "6901", ack: "true" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      post authenticate_logistics_account_path
      expect(response).to redirect_to(logistics_account_path)

      account.reload
      expect(account.customer_id).to eq("6581")
      expect(account.customer_userid).to eq("6901")
    end

    it "handles RaydoService::Error gracefully with a flash alert (never a 500)" do
      create(:logistics_account, company: company, username: "TEST", password: "wrong",
             url1_base: "http://raydo.test:8082")
      stub_request(:get, "http://raydo.test:8082/selectAuth.htm")
        .with(query: hash_including({}))
        .to_return(body: { ack: "false" }.to_json, headers: { "Content-Type" => "application/json" })

      post authenticate_logistics_account_path
      expect(response).to redirect_to(logistics_account_path)
      follow_redirect!
      expect(response.body).to include("Raydo")
    end
  end

  describe "permission gate" do
    let!(:gate_company) { company }

    it "allows a member granted the logistics_channels permission" do
      m = create(:user)
      create(:membership, user: m, company: gate_company, role: :member, permissions: [ "logistics_channels" ])
      sign_in m
      patch switch_company_path(id: gate_company.id)

      get logistics_account_path
      expect(response).to have_http_status(:ok)
    end

    it "denies a member without the logistics_channels permission" do
      m = create(:user)
      create(:membership, user: m, company: gate_company, role: :member, permissions: [ "shopify_stores" ])
      sign_in m
      patch switch_company_path(id: gate_company.id)

      get logistics_account_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "cross-company isolation" do
    it "never exposes another company's cached customer ids" do
      create(:logistics_account, company: company, customer_id: "SECRET-6581", customer_userid: "SECRET-6901")

      other_owner = create(:user)
      sign_in other_owner

      get logistics_account_path
      expect(response.body).not_to include("SECRET-6581")
      expect(response.body).not_to include("SECRET-6901")
    end

    it "never lets a member update another company's account" do
      account = create(:logistics_account, company: company, username: "ORIGINAL")

      other_owner = create(:user)
      sign_in other_owner
      patch logistics_account_path, params: { logistics_account: { username: "HIJACKED" } }

      expect(account.reload.username).to eq("ORIGINAL")
    end
  end
end
