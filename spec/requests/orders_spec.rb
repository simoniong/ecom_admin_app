require "rails_helper"

RSpec.describe "Orders", type: :request do
  let(:user) { create(:user) }
  let(:customer) { create(:customer, first_name: "John", last_name: "Doe", email: "john@example.com") }

  describe "GET /orders" do
    it "returns success for authenticated user" do
      sign_in user
      get orders_path
      expect(response).to have_http_status(:success)
    end

    it "redirects unauthenticated user" do
      get orders_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "shows empty state when no orders" do
      sign_in user
      get orders_path
      expect(response.body).to include("No orders found")
    end

    it "lists orders with details" do
      order = create(:order, customer: customer, name: "#1001", total_price: 149.99, ordered_at: 1.day.ago)
      create(:fulfillment, order: order, tracking_number: "TRACK123", tracking_company: "USPS")

      sign_in user
      get orders_path
      expect(response.body).to include("#1001")
      expect(response.body).to include("John")
      expect(response.body).to include("$149.99")
      expect(response.body).to include("TRACK123")
      expect(response.body).to include("USPS")
    end

    it "filters by date range" do
      recent = create(:order, customer: customer, name: "#2001", ordered_at: 1.day.ago)
      old = create(:order, customer: customer, name: "#2002", ordered_at: 60.days.ago)

      sign_in user
      get orders_path, params: { from_date: 3.days.ago.to_date, to_date: Date.current }
      expect(response.body).to include("#2001")
      expect(response.body).not_to include("#2002")
    end

    it "searches by email" do
      create(:order, customer: customer, name: "#3001", email: "john@example.com")
      other_customer = create(:customer, first_name: "Alice", last_name: "Wonder", email: "other@example.com")
      create(:order, customer: other_customer, name: "#3002", email: "other@example.com")

      sign_in user
      get orders_path, params: { search: "john", from_date: 30.days.ago.to_date }
      expect(response.body).to include("#3001")
      expect(response.body).not_to include("#3002")
    end

    it "searches by customer name" do
      create(:order, customer: customer, name: "#4001")
      other_customer = create(:customer, first_name: "Alice", last_name: "Wonder")
      create(:order, customer: other_customer, name: "#4002")

      sign_in user
      get orders_path, params: { search: "Doe", from_date: 30.days.ago.to_date }
      expect(response.body).to include("#4001")
      expect(response.body).not_to include("#4002")
    end

    it "filters by financial status" do
      create(:order, customer: customer, name: "#5001", financial_status: "paid")
      create(:order, customer: customer, name: "#5002", financial_status: "pending")

      sign_in user
      get orders_path, params: { financial_status: "paid", from_date: 30.days.ago.to_date }
      expect(response.body).to include("#5001")
      expect(response.body).not_to include("#5002")
    end

    it "filters by fulfillment status" do
      create(:order, customer: customer, name: "#6001", fulfillment_status: "fulfilled")
      create(:order, customer: customer, name: "#6002", fulfillment_status: nil)

      sign_in user
      get orders_path, params: { fulfillment_status: "fulfilled", from_date: 30.days.ago.to_date }
      expect(response.body).to include("#6001")
      expect(response.body).not_to include("#6002")
    end

    it "shows date range quick pick buttons" do
      sign_in user
      get orders_path
      expect(response.body).to include("Today")
      expect(response.body).to include("Yesterday")
      expect(response.body).to include("This Week")
      expect(response.body).to include("Last Week")
    end

    it "shows financial status badges" do
      create(:order, customer: customer, financial_status: "paid")
      create(:order, customer: customer, financial_status: "pending")

      sign_in user
      get orders_path, params: { from_date: 30.days.ago.to_date }
      expect(response.body).to include("Paid")
      expect(response.body).to include("Pending")
    end

    it "shows summary with order count and revenue" do
      create(:order, customer: customer, total_price: 100.00)
      create(:order, customer: customer, total_price: 200.00)

      sign_in user
      get orders_path, params: { from_date: 30.days.ago.to_date }
      expect(response.body).to include("Total Orders")
      expect(response.body).to include("Total Revenue")
    end

    it "handles invalid date gracefully" do
      sign_in user
      get orders_path, params: { from_date: "not-a-date" }
      expect(response).to have_http_status(:success)
    end

    it "sorts by total_price" do
      create(:order, customer: customer, name: "#7001", total_price: 50.00)
      create(:order, customer: customer, name: "#7002", total_price: 500.00)

      sign_in user
      get orders_path, params: { sort_column: "total_price", sort_direction: "desc", from_date: 30.days.ago.to_date }
      body = response.body
      expect(body.index("#7002")).to be < body.index("#7001")
    end

    it "paginates results" do
      30.times { create(:order, customer: customer) }

      sign_in user
      get orders_path, params: { from_date: 30.days.ago.to_date }
      expect(response.body).to include("Showing 1-25 of 30")
      expect(response.body).to include("Next")
    end

    it "shows order source from shopify_data" do
      create(:order, customer: customer, shopify_data: { "source_name" => "pos" })

      sign_in user
      get orders_path, params: { from_date: 30.days.ago.to_date }
      expect(response.body).to include("pos")
    end
  end

  describe "POST /orders/sync" do
    it "enqueues sync jobs for all stores and redirects" do
      store = create(:shopify_store, user: user)

      sign_in user
      expect {
        post sync_orders_path
      }.to have_enqueued_job(SyncAllShopifyOrdersJob).with(store.id)

      expect(response).to redirect_to(orders_path)
      follow_redirect!
      expect(response.body).to include("sync")
    end

    it "redirects unauthenticated user" do
      post sync_orders_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "enqueues a job for each store" do
      store1 = create(:shopify_store, user: user)
      store2 = create(:shopify_store, user: user)

      sign_in user
      post sync_orders_path

      expect(SyncAllShopifyOrdersJob).to have_been_enqueued.with(store1.id)
      expect(SyncAllShopifyOrdersJob).to have_been_enqueued.with(store2.id)
    end
  end
end
