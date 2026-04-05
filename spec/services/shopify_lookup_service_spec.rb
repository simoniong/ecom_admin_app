require "rails_helper"

RSpec.describe ShopifyLookupService do
  let(:shopify_service) { instance_double(ShopifyService) }
  let(:service) { described_class.new(shopify_service: shopify_service) }
  let(:ticket) { create(:ticket, customer_email: "buyer@example.com") }

  describe "#lookup" do
    it "creates customer, orders, and fulfillments from Shopify data" do
      allow(shopify_service).to receive(:find_customers_by_email).with("buyer@example.com").and_return([
        { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane", "last_name" => "Buyer", "phone" => "+1555" }
      ])

      allow(shopify_service).to receive(:fetch_orders).with(100).and_return([
        { "id" => 200, "email" => "buyer@example.com", "name" => "#1001", "total_price" => "49.99",
          "currency" => "USD", "financial_status" => "paid", "fulfillment_status" => "fulfilled", "created_at" => "2026-03-20" }
      ])

      allow(shopify_service).to receive(:fetch_fulfillments).with(200).and_return([
        { "id" => 300, "status" => "success", "tracking_number" => "TRACK1", "tracking_company" => "USPS", "tracking_url" => "https://track.example.com" }
      ])

      expect { service.lookup(ticket) }.to change(Customer, :count).by(1)
        .and change(Order, :count).by(1)
        .and change(Fulfillment, :count).by(1)

      ticket.reload
      expect(ticket.customer).to be_present
      expect(ticket.customer.email).to eq("buyer@example.com")
      expect(ticket.customer.orders.first.name).to eq("#1001")
      expect(ticket.customer.orders.first.fulfillments.first.tracking_number).to eq("TRACK1")
    end

    it "does nothing when no Shopify customer found" do
      allow(shopify_service).to receive(:find_customers_by_email).and_return([])

      expect { service.lookup(ticket) }.not_to change(Customer, :count)
      expect(ticket.reload.customer).to be_nil
    end

    it "returns nil when ticket has no shopify store" do
      service_without_shopify = described_class.new
      ticket_no_store = create(:ticket, customer_email: "nobody@example.com")

      expect { service_without_shopify.lookup(ticket_no_store) }.not_to change(Customer, :count)
      expect(ticket_no_store.reload.customer).to be_nil
    end

    it "auto-resolves ShopifyService from ticket email_account store" do
      store = create(:shopify_store)
      email_account = create(:email_account, shopify_store: store, user: store.user)
      ticket_with_store = create(:ticket, email_account: email_account, customer_email: "auto@example.com")

      shopify_svc = instance_double(ShopifyService)
      allow(ShopifyService).to receive(:new).with(store).and_return(shopify_svc)
      allow(shopify_svc).to receive(:find_customers_by_email).and_return([
        { "id" => 500, "email" => "auto@example.com", "first_name" => "Auto", "last_name" => "User" }
      ])
      allow(shopify_svc).to receive(:fetch_orders).and_return([])

      service_auto = described_class.new
      service_auto.lookup(ticket_with_store)

      expect(ticket_with_store.reload.customer).to be_present
      expect(ticket_with_store.customer.email).to eq("auto@example.com")
    end

    it "handles customer RecordNotUnique race condition" do
      store = ticket.email_account&.shopify_store || create(:shopify_store)
      shopify_customer = { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane", "last_name" => "Buyer" }

      allow(shopify_service).to receive(:find_customers_by_email).and_return([ shopify_customer ])
      allow(shopify_service).to receive(:fetch_orders).and_return([])

      # First call creates the customer
      service.lookup(ticket)

      # Simulate race: find_or_initialize_by returns new record, save! raises unique
      new_customer = Customer.new(shopify_store: ticket.customer.shopify_store, shopify_customer_id: 100)
      allow(Customer).to receive(:find_or_initialize_by).and_return(new_customer)
      allow(new_customer).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

      expect { service.lookup(ticket) }.not_to raise_error
    end

    it "handles order RecordNotUnique race condition" do
      allow(shopify_service).to receive(:find_customers_by_email).and_return([
        { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane", "last_name" => "Buyer" }
      ])
      allow(shopify_service).to receive(:fetch_orders).and_return([
        { "id" => 200, "name" => "#1001", "total_price" => "49.99", "currency" => "USD",
          "financial_status" => "paid", "created_at" => "2026-03-20" }
      ])
      allow(shopify_service).to receive(:fetch_fulfillments).and_return([])

      # First call creates customer + order
      service.lookup(ticket)
      customer = ticket.reload.customer

      # Simulate race on order upsert
      new_order = customer.orders.build(shopify_store: customer.shopify_store, shopify_order_id: 200)
      allow(customer.orders).to receive(:find_or_initialize_by).and_return(new_order)
      allow(new_order).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

      expect { service.lookup(ticket) }.not_to raise_error
    end

    it "is idempotent — does not create duplicates" do
      shopify_customer = { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane", "last_name" => "Buyer" }
      shopify_order = { "id" => 200, "name" => "#1001", "total_price" => "49.99", "currency" => "USD",
                        "financial_status" => "paid", "created_at" => "2026-03-20" }
      shopify_fulfillment = { "id" => 300, "status" => "success", "tracking_number" => "T1" }

      allow(shopify_service).to receive(:find_customers_by_email).and_return([ shopify_customer ])
      allow(shopify_service).to receive(:fetch_orders).and_return([ shopify_order ])
      allow(shopify_service).to receive(:fetch_fulfillments).and_return([ shopify_fulfillment ])

      service.lookup(ticket)
      expect { service.lookup(ticket) }.not_to change(Customer, :count)
    end
  end
end
