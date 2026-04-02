require "rails_helper"

RSpec.describe SyncAllOrdersService do
  let(:store) { create(:shopify_store) }
  let(:shopify_service) { instance_double(ShopifyService) }
  let(:service) { described_class.new(store) }

  before do
    allow(ShopifyService).to receive(:new).with(store).and_return(shopify_service)
  end

  describe "#call" do
    let(:shopify_customer) do
      { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane", "last_name" => "Buyer" }
    end

    let(:shopify_order) do
      {
        "id" => 200, "email" => "buyer@example.com", "name" => "#1001",
        "total_price" => "49.99", "currency" => "USD",
        "financial_status" => "paid", "fulfillment_status" => "fulfilled",
        "created_at" => "2026-03-20",
        "customer" => shopify_customer,
        "fulfillments" => [
          { "id" => 300, "status" => "success", "tracking_number" => "TRACK1",
            "tracking_company" => "USPS", "tracking_url" => "https://track.example.com" }
        ]
      }
    end

    before do
      allow(shopify_service).to receive(:fetch_all_customers).and_return([ shopify_customer ], [])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([ shopify_order ], [])
    end

    it "creates customers, orders, and fulfillments" do
      expect { service.call }.to change(Customer, :count).by(1)
        .and change(Order, :count).by(1)
        .and change(Fulfillment, :count).by(1)
    end

    it "returns sync counts" do
      result = service.call
      expect(result).to eq(customers: 1, orders: 1)
    end

    it "sets correct order attributes" do
      service.call

      order = Order.find_by(shopify_order_id: 200)
      expect(order.name).to eq("#1001")
      expect(order.total_price).to eq(49.99)
      expect(order.financial_status).to eq("paid")
      expect(order.customer.email).to eq("buyer@example.com")
    end

    it "sets correct fulfillment attributes" do
      service.call

      fulfillment = Fulfillment.find_by(shopify_fulfillment_id: 300)
      expect(fulfillment.tracking_number).to eq("TRACK1")
      expect(fulfillment.tracking_company).to eq("USPS")
    end

    it "is idempotent — does not create duplicates" do
      service.call

      allow(shopify_service).to receive(:fetch_all_customers).and_return([ shopify_customer ], [])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([ shopify_order ], [])

      expect { described_class.new(store).call }.not_to change(Order, :count)
    end

    it "paginates through orders using since_id" do
      order1 = shopify_order.merge("id" => 200)
      order2 = shopify_order.merge("id" => 201, "name" => "#1002")

      allow(shopify_service).to receive(:fetch_all_orders)
        .with(since_id: nil, updated_at_min: nil).and_return(Array.new(250, order1))
      allow(shopify_service).to receive(:fetch_all_orders)
        .with(since_id: 200, updated_at_min: nil).and_return([ order2 ])

      service.call

      expect(shopify_service).to have_received(:fetch_all_orders).twice
    end

    it "updates orders_synced_at after sync" do
      service.call
      expect(store.reload.orders_synced_at).to be_present
    end

    it "handles orders without customer gracefully" do
      order_no_customer = shopify_order.merge("customer" => nil)
      allow(shopify_service).to receive(:fetch_all_orders).and_return([ order_no_customer ], [])

      expect { service.call }.not_to raise_error
      expect(Order.count).to eq(0)
    end

    it "fetches fulfillments from API when not embedded" do
      order_without_fulfillments = shopify_order.merge("fulfillments" => [])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([ order_without_fulfillments ], [])
      allow(shopify_service).to receive(:fetch_fulfillments).with(200).and_return([
        { "id" => 300, "status" => "success", "tracking_number" => "TRACK1" }
      ])

      service.call

      expect(shopify_service).to have_received(:fetch_fulfillments).with(200)
      expect(Fulfillment.count).to eq(1)
    end

    it "continues syncing when an individual order fails" do
      bad_order = { "id" => 999, "customer" => { "id" => nil }, "fulfillments" => [] }
      good_order = shopify_order.merge("id" => 201, "name" => "#1002")

      allow(shopify_service).to receive(:fetch_all_orders).and_return([ bad_order, good_order ], [])

      service.call
      expect(Order.find_by(shopify_order_id: 201)).to be_present
    end
  end

  describe "#call with incremental mode" do
    let(:shopify_customer) do
      { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane", "last_name" => "Buyer" }
    end

    let(:shopify_order) do
      {
        "id" => 200, "email" => "buyer@example.com", "name" => "#1001",
        "total_price" => "49.99", "currency" => "USD",
        "financial_status" => "paid", "fulfillment_status" => "fulfilled",
        "created_at" => "2026-03-20",
        "customer" => shopify_customer,
        "fulfillments" => []
      }
    end

    it "passes updated_at_min when incremental and orders_synced_at is set" do
      store.update!(orders_synced_at: 1.hour.ago)
      last_sync = store.reload.orders_synced_at # DB-rounded precision

      allow(shopify_service).to receive(:fetch_all_customers).and_return([])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([])

      service.call(incremental: true)

      expect(shopify_service).to have_received(:fetch_all_orders).with(since_id: nil, updated_at_min: last_sync)
      expect(shopify_service).to have_received(:fetch_all_customers).with(since_id: nil, updated_at_min: last_sync)
    end

    it "does full sync when incremental but orders_synced_at is nil" do
      allow(shopify_service).to receive(:fetch_all_customers).and_return([])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([])

      service.call(incremental: true)

      expect(shopify_service).to have_received(:fetch_all_orders).with(since_id: nil, updated_at_min: nil)
    end
  end

  describe "#sync_single_order" do
    let(:shopify_customer) do
      { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane", "last_name" => "Buyer" }
    end

    let(:shopify_order) do
      {
        "id" => 200, "email" => "buyer@example.com", "name" => "#1001",
        "total_price" => "49.99", "currency" => "USD",
        "financial_status" => "paid", "fulfillment_status" => "fulfilled",
        "created_at" => "2026-03-20",
        "customer" => shopify_customer,
        "fulfillments" => [
          { "id" => 300, "status" => "success", "tracking_number" => "TRACK1",
            "tracking_company" => "USPS", "tracking_url" => "https://track.example.com" }
        ]
      }
    end

    it "creates order with customer and fulfillments" do
      expect { service.sync_single_order(shopify_order) }
        .to change(Order, :count).by(1)
        .and change(Customer, :count).by(1)
        .and change(Fulfillment, :count).by(1)
    end

    it "skips orders without customer" do
      order_no_customer = shopify_order.merge("customer" => nil)
      expect { service.sync_single_order(order_no_customer) }.not_to change(Order, :count)
    end
  end
end
