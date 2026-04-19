require "rails_helper"

RSpec.describe "Data isolation across groups", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let!(:group_a) { create(:group, company: company, name: "Sales") }
  let!(:group_b) { create(:group, company: company, name: "Support") }

  let(:member_a) do
    u = create(:user)
    create(:membership, company: company, user: u, role: :member,
           permissions: %w[dashboard orders tickets ad_accounts shopify_stores email_accounts shipments ad_campaigns],
           group: group_a)
    u
  end

  let(:member_b) do
    u = create(:user)
    create(:membership, company: company, user: u, role: :member,
           permissions: %w[dashboard orders tickets ad_accounts shopify_stores email_accounts shipments ad_campaigns],
           group: group_b)
    u
  end

  let!(:store_a) { create(:shopify_store, company: company, user: owner, group: group_a, shop_domain: "store-a.myshopify.com") }
  let!(:store_b) { create(:shopify_store, company: company, user: owner, group: group_b, shop_domain: "store-b.myshopify.com") }
  let!(:ad_a) { create(:ad_account, company: company, user: owner, group: group_a, account_id: "act_sales", account_name: "SALES_AD") }
  let!(:ad_b) { create(:ad_account, company: company, user: owner, group: group_b, account_id: "act_support", account_name: "SUPPORT_AD") }
  let!(:email_a) { create(:email_account, company: company, user: owner, group: group_a, email: "sales@example.com") }
  let!(:email_b) { create(:email_account, company: company, user: owner, group: group_b, email: "support@example.com") }

  context "ShopifyStore index" do
    it "owner sees all stores" do
      sign_in owner
      get shopify_stores_path
      expect(response.body).to include("store-a.myshopify.com")
      expect(response.body).to include("store-b.myshopify.com")
    end

    it "member sees only their group's stores" do
      sign_in member_a
      patch switch_company_path(id: company.id)
      get shopify_stores_path
      expect(response.body).to include("store-a.myshopify.com")
      expect(response.body).not_to include("store-b.myshopify.com")
    end
  end

  context "ShopifyStore show" do
    it "member cannot access a store in a different group" do
      sign_in member_a
      patch switch_company_path(id: company.id)

      get shopify_store_path(id: store_b.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  context "AdAccount index" do
    it "member sees only their group's ad accounts" do
      sign_in member_a
      patch switch_company_path(id: company.id)
      get ad_accounts_path
      expect(response.body).to include("SALES_AD")
      expect(response.body).not_to include("SUPPORT_AD")
    end
  end

  context "EmailAccount index" do
    it "member sees only their group's email accounts" do
      sign_in member_a
      patch switch_company_path(id: company.id)
      get email_accounts_path
      expect(response.body).to include("sales@example.com")
      expect(response.body).not_to include("support@example.com")
    end
  end

  context "Orders" do
    it "member sees only orders from their group's stores" do
      customer_a = create(:customer, shopify_store: store_a)
      customer_b = create(:customer, shopify_store: store_b)
      order_a = create(:order, customer: customer_a, shopify_store: store_a, name: "#ORD-SALES")
      order_b = create(:order, customer: customer_b, shopify_store: store_b, name: "#ORD-SUPPORT")

      sign_in member_a
      patch switch_company_path(id: company.id)
      get orders_path

      expect(response.body).to include("ORD-SALES")
      expect(response.body).not_to include("ORD-SUPPORT")
    end
  end

  context "Tickets" do
    it "member sees only tickets in their group's email accounts" do
      ticket_a = create(:ticket, email_account: email_a, customer_email: "cust-a@example.com", subject: "Ticket from Sales")
      ticket_b = create(:ticket, email_account: email_b, customer_email: "cust-b@example.com", subject: "Ticket from Support")

      sign_in member_a
      patch switch_company_path(id: company.id)
      get tickets_path

      expect(response.body).to include("Ticket from Sales")
      expect(response.body).not_to include("Ticket from Support")
    end

    it "member cannot access a ticket in another group" do
      ticket_b = create(:ticket, email_account: email_b, customer_email: "cust-b@example.com", subject: "Ticket from Support")

      sign_in member_a
      patch switch_company_path(id: company.id)
      get ticket_path(id: ticket_b.id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
