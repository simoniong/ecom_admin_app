require "rails_helper"

RSpec.describe "Shipments", type: :request do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user) }
  let(:customer) { create(:customer, shopify_store: store) }

  before { sign_in user }

  describe "GET /shipments" do
    it "renders the index page" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "TRACK1", tracking_status: "InTransit")

      get shipments_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("TRACK1")
    end

    it "shows status tab counts" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "T1", tracking_status: "InTransit")
      create(:fulfillment, order: order, tracking_number: "T2", tracking_status: "Delivered")
      create(:fulfillment, order: order, tracking_number: "T3", tracking_status: "Delivered")

      get shipments_path
      expect(response.body).to include("All (3)")
      expect(response.body).to include("In Transit (1)")
      expect(response.body).to include("Delivered (2)")
    end

    it "filters by status tab" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "T1", tracking_status: "InTransit")
      create(:fulfillment, order: order, tracking_number: "T2", tracking_status: "Delivered")

      get shipments_path, params: { status_tab: "InTransit" }
      expect(response.body).to include("T1")
      expect(response.body).not_to include("T2")
    end

    it "filters by search query on tracking number" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "DOR019055CN", tracking_status: "InTransit")
      create(:fulfillment, order: order, tracking_number: "OTHER123", tracking_status: "InTransit")

      get shipments_path, params: { search: "DOR019" }
      expect(response.body).to include("DOR019055CN")
      expect(response.body).not_to include("OTHER123")
    end

    it "filters by destination country" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "T1", tracking_status: "InTransit", destination_country: "US")
      create(:fulfillment, order: order, tracking_number: "T2", tracking_status: "InTransit", destination_country: "AU")

      get shipments_path, params: { destination: "US" }
      expect(response.body).to include("T1")
      expect(response.body).not_to include("T2")
    end

    it "filters by origin carrier" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "T1", tracking_status: "InTransit", origin_carrier: "China Post")
      create(:fulfillment, order: order, tracking_number: "T2", tracking_status: "InTransit", origin_carrier: "DHL")

      get shipments_path, params: { origin_carrier: "China Post" }
      expect(response.body).to include("T1")
      expect(response.body).not_to include("T2")
    end

    it "sorts by sort_field and sort_direction" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "OLD", tracking_status: "InTransit", created_at: 2.days.ago)
      create(:fulfillment, order: order, tracking_number: "NEW", tracking_status: "InTransit", created_at: 1.hour.ago)

      get shipments_path, params: { sort_field: "input_time", sort_direction: "asc" }
      expect(response.body.index("OLD")).to be < response.body.index("NEW")
    end

    it "paginates results" do
      order = create(:order, customer: customer, shopify_store: store)
      30.times { |i| create(:fulfillment, order: order, tracking_number: "TRACK#{i}", tracking_status: "InTransit") }

      get shipments_path, params: { page: 1 }
      expect(response.body).to include("Showing 1-25 of 30")
    end

    it "only shows shipments for current user stores" do
      other_user = create(:user)
      other_store = create(:shopify_store, user: other_user)
      other_customer = create(:customer, shopify_store: other_store)
      other_order = create(:order, customer: other_customer, shopify_store: other_store)
      create(:fulfillment, order: other_order, tracking_number: "OTHER_STORE", tracking_status: "InTransit")

      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "MY_STORE", tracking_status: "InTransit")

      get shipments_path
      expect(response.body).to include("MY_STORE")
      expect(response.body).not_to include("OTHER_STORE")
    end
  end

  describe "POST /shipments/sync" do
    it "enqueues sync jobs and redirects" do
      store # ensure store exists

      expect {
        post sync_shipments_path
      }.to have_enqueued_job(SyncAllShopifyOrdersJob).with(store.id)

      expect(response).to redirect_to(shipments_path)
    end
  end
end
