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

    it "handles order save race condition via RecordNotUnique" do
      service.call
      existing_order = Order.find_by(shopify_order_id: 200)

      # Stub find_or_initialize_by to return a new (unsaved) Order that will collide
      allow(Order).to receive(:find_or_initialize_by).and_wrap_original do |method, **args|
        result = method.call(**args)
        if result.persisted?
          # Return a new record to force the unique constraint path
          new_record = Order.new(args)
          allow(new_record).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)
          new_record
        else
          result
        end
      end

      allow(shopify_service).to receive(:fetch_all_customers).and_return([ shopify_customer ], [])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([ shopify_order ], [])

      expect { described_class.new(store).call }.not_to raise_error
      expect(existing_order.reload.name).to eq("#1001")
    end

    it "handles customer save race condition via RecordNotUnique" do
      service.call
      existing = Customer.find_by(shopify_customer_id: 100)

      allow(Customer).to receive(:find_or_initialize_by).and_wrap_original do |method, **args|
        result = method.call(**args)
        if result.persisted?
          new_record = Customer.new(args)
          allow(new_record).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)
          new_record
        else
          result
        end
      end

      allow(shopify_service).to receive(:fetch_all_customers).and_return([ shopify_customer ], [])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([])

      expect { described_class.new(store).call }.not_to raise_error
      expect(existing.reload).to be_present
    end

    it "updates existing fulfillment found globally instead of raising uniqueness error" do
      service.call

      # Simulate full re-sync: fulfillment already exists from first sync
      existing_fulfillment = Fulfillment.find_by(shopify_fulfillment_id: 300)
      expect(existing_fulfillment).to be_present

      updated_order = shopify_order.merge(
        "fulfillments" => [
          { "id" => 300, "status" => "success", "tracking_number" => "TRACK_UPDATED",
            "tracking_company" => "FedEx", "tracking_url" => "https://track2.example.com" }
        ]
      )
      allow(shopify_service).to receive(:fetch_all_customers).and_return([ shopify_customer ], [])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([ updated_order ], [])

      expect { described_class.new(store).call }.not_to change(Fulfillment, :count)
      expect(existing_fulfillment.reload.tracking_number).to eq("TRACK_UPDATED")
      expect(existing_fulfillment.tracking_company).to eq("FedEx")
    end

    it "handles fulfillment save race condition via RecordNotUnique" do
      service.call
      existing = Fulfillment.find_by(shopify_fulfillment_id: 300)

      new_fulfillment = Fulfillment.new(shopify_fulfillment_id: 300)
      allow(Fulfillment).to receive(:find_or_initialize_by).and_return(new_fulfillment)
      allow(new_fulfillment).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

      allow(shopify_service).to receive(:fetch_all_customers).and_return([ shopify_customer ], [])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([ shopify_order ], [])

      expect { described_class.new(store).call }.not_to raise_error
      expect(existing.reload).to be_present
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

  describe "#call link_orphaned_tickets" do
    let(:shopify_customer) do
      { "id" => 100, "email" => "orphan@example.com", "first_name" => "Jane", "last_name" => "Buyer" }
    end

    before do
      allow(shopify_service).to receive(:fetch_all_customers).and_return([ shopify_customer ], [])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([])
    end

    it "links orphaned tickets to matching customers by email" do
      email_account = create(:email_account, shopify_store: store, user: store.user)
      ticket = create(:ticket, email_account: email_account, customer_email: "orphan@example.com", customer: nil)

      service.call

      expect(ticket.reload.customer).to be_present
      expect(ticket.customer.email).to eq("orphan@example.com")
    end

    it "does not overwrite tickets that already have a customer" do
      existing_customer = create(:customer, shopify_store: store, email: "other@example.com")
      email_account = create(:email_account, shopify_store: store, user: store.user)
      ticket = create(:ticket, email_account: email_account, customer_email: "orphan@example.com", customer: existing_customer)

      service.call

      expect(ticket.reload.customer).to eq(existing_customer)
    end

    it "skips tickets with 'unknown' sentinel email" do
      email_account = create(:email_account, shopify_store: store, user: store.user)
      ticket = create(:ticket, email_account: email_account, customer_email: "unknown", customer: nil)

      service.call

      expect(ticket.reload.customer).to be_nil
    end

    it "skips tickets with email missing @ sign" do
      email_account = create(:email_account, shopify_store: store, user: store.user)
      ticket = create(:ticket, email_account: email_account, customer_email: "not-an-email", customer: nil)

      service.call

      expect(ticket.reload.customer).to be_nil
    end

    it "skips tickets from email accounts not linked to this store" do
      other_store = create(:shopify_store)
      other_email_account = create(:email_account, shopify_store: other_store, user: other_store.user)
      ticket = create(:ticket, email_account: other_email_account, customer_email: "orphan@example.com", customer: nil)

      # Create a customer in the current store with matching email
      create(:customer, shopify_store: store, email: "orphan@example.com")

      service.call

      expect(ticket.reload.customer).to be_nil
    end

    it "links multiple orphaned tickets in one sync run" do
      email_account = create(:email_account, shopify_store: store, user: store.user)
      ticket_a = create(:ticket, email_account: email_account, customer_email: "orphan@example.com", customer: nil)
      ticket_b = create(:ticket, email_account: email_account, customer_email: "orphan@example.com", customer: nil)

      service.call

      expect(ticket_a.reload.customer).to be_present
      expect(ticket_b.reload.customer).to be_present
      expect(ticket_a.customer).to eq(ticket_b.customer)
    end

    it "does not link tickets when no customer matches the email" do
      email_account = create(:email_account, shopify_store: store, user: store.user)
      ticket = create(:ticket, email_account: email_account, customer_email: "nomatch@example.com", customer: nil)

      service.call

      expect(ticket.reload.customer).to be_nil
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

  describe "line item sync" do
    let(:shopify_customer) do
      { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane", "last_name" => "Buyer" }
    end

    let!(:product) { create(:product, shopify_store: store, shopify_product_id: 7001) }
    let!(:variant_a) do
      create(:product_variant, product: product, shopify_variant_id: 8001, unit_cost: 90)
    end

    before { store.update!(cost_fx_rate: 7.2) }  # 1 USD = 7.2 CNY

    let(:shopify_order_with_lines) do
      {
        "id" => 200, "email" => "buyer@example.com", "name" => "#1001",
        "total_price" => "73.00", "currency" => "USD",
        "financial_status" => "paid", "fulfillment_status" => "fulfilled",
        "created_at" => "2026-03-20",
        "customer" => shopify_customer,
        "line_items" => [
          { "id" => 6001, "variant_id" => 8001, "sku" => "PK-BL", "title" => "Paint / Black",
            "quantity" => 2, "price" => "29.00" },
          { "id" => 6002, "variant_id" => 9999, "sku" => "UNKNOWN", "title" => "Mystery",
            "quantity" => 1, "price" => "15.00" }
        ],
        "fulfillments" => []
      }
    end

    before do
      allow(shopify_service).to receive(:fetch_all_customers).and_return([ shopify_customer ], [])
      allow(shopify_service).to receive(:fetch_all_orders).and_return([ shopify_order_with_lines ], [])
      allow(shopify_service).to receive(:fetch_fulfillments).and_return([])
    end

    it "creates OrderLineItem rows from each line item in the shopify payload" do
      expect { service.call }.to change(OrderLineItem, :count).by(2)
    end

    it "snapshots unit_cost from matching variant, converted from CNY to store currency" do
      service.call
      li = OrderLineItem.find_by(shopify_line_item_id: 6001)
      expect(li.product_variant).to eq(variant_a)
      # 90 CNY / 7.2 = 12.50 USD
      expect(li.unit_cost_snapshot).to eq(12.50)
      expect(li.quantity).to eq(2)
      expect(li.unit_price).to eq(29.00)
    end

    it "includes packaging_cost in the snapshot cost basis" do
      variant_a.update!(packaging_cost: 9.00)
      service.call
      li = OrderLineItem.find_by(shopify_line_item_id: 6001)
      # (90 + 9) CNY / 7.2 = 13.75 USD
      expect(li.unit_cost_snapshot).to eq(13.75)
    end

    it "snapshots packaging_cost alone when unit_cost is zero" do
      variant_a.update!(unit_cost: 0, packaging_cost: 9.00)
      service.call
      li = OrderLineItem.find_by(shopify_line_item_id: 6001)
      # (0 + 9) CNY / 7.2 = 1.25 USD
      expect(li.unit_cost_snapshot).to eq(1.25)
    end

    it "leaves snapshot nil when unit_cost is nil even if packaging_cost is set" do
      variant_a.update!(unit_cost: nil, packaging_cost: 5.00)
      service.call
      li = OrderLineItem.find_by(shopify_line_item_id: 6001)
      expect(li.unit_cost_snapshot).to be_nil
    end

    it "leaves snapshot nil when store.cost_fx_rate is not set" do
      store.update!(cost_fx_rate: nil)
      service.call
      li = OrderLineItem.find_by(shopify_line_item_id: 6001)
      expect(li.unit_cost_snapshot).to be_nil
    end

    it "saves the line item with null variant when variant_id is unknown" do
      service.call
      li = OrderLineItem.find_by(shopify_line_item_id: 6002)
      expect(li.product_variant).to be_nil
      expect(li.unit_cost_snapshot).to be_nil
      expect(li.sku_at_sale).to eq("UNKNOWN")
    end

    it "does not overwrite existing snapshot on re-sync" do
      service.call
      OrderLineItem.find_by(shopify_line_item_id: 6001).update!(unit_cost_snapshot: 7.77)

      allow(shopify_service).to receive(:fetch_all_orders).and_return([ shopify_order_with_lines ], [])
      described_class.new(store).call

      expect(OrderLineItem.find_by(shopify_line_item_id: 6001).unit_cost_snapshot).to eq(7.77)
    end

    context "multi-currency (Shopify Markets)" do
      let(:multi_currency_order) do
        {
          "id" => 200, "email" => "buyer@example.com", "name" => "#1001",
          "total_price" => "60.00", "currency" => "EUR",
          "current_total_price_set" => {
            "shop_money" => { "amount" => "73.00", "currency_code" => "USD" }
          },
          "financial_status" => "paid", "fulfillment_status" => "fulfilled",
          "created_at" => "2026-03-20",
          "customer" => shopify_customer,
          "line_items" => [
            {
              "id" => 6001, "variant_id" => 8001, "sku" => "PK-BL", "title" => "Paint / Black",
              "quantity" => 2,
              "price" => "24.00",
              "price_set" => {
                "shop_money" => { "amount" => "29.00", "currency_code" => "USD" }
              }
            }
          ],
          "fulfillments" => []
        }
      end

      before do
        allow(shopify_service).to receive(:fetch_all_orders).and_return([ multi_currency_order ], [])
      end

      it "stores order total_price using shop_money (store currency)" do
        service.call
        order = Order.find_by(shopify_order_id: 200)
        expect(order.total_price).to eq(73.00)
        expect(order.currency).to eq("USD")
      end

      it "stores line item unit_price using shop_money (store currency)" do
        service.call
        li = OrderLineItem.find_by(shopify_line_item_id: 6001)
        expect(li.unit_price).to eq(29.00)
        expect(li.currency).to eq("USD")
      end
    end
  end

  describe "estimated shipping cost snapshot" do
    let(:shopify_customer) do
      { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane", "last_name" => "Buyer" }
    end

    let!(:product) { create(:product, shopify_store: store, shopify_product_id: 7001) }
    let!(:variant_300g) do
      create(:product_variant, product: product, shopify_variant_id: 8001, weight_grams: 300)
    end

    # Rate card: 0.3 kg * 92.0 CNY/kg + 23.0 CNY flat + 2 CNY op fee = 52.6 CNY / 7.0 = 7.51 USD
    let!(:rate_card_version) do
      create(:shipping_rate_card_version,
             company: store.company,
             country_code: "US",
             service_type: "with_battery",
             effective_from: Date.new(2026, 1, 1),
             effective_to: nil)
    end

    let!(:rate_card_rate) do
      create(:shipping_rate_card_rate,
             version: rate_card_version,
             weight_min_kg: 0.201,
             weight_max_kg: 0.45,
             per_kg_rate_cny: 92.0,
             flat_fee_cny: 23.0)
    end

    # Shopify order payload: US shipping address, April 2026, 0.3 kg variant
    let(:shopify_order_with_weight) do
      {
        "id" => 200, "email" => "buyer@example.com", "name" => "#1001",
        "total_price" => "49.99", "currency" => "USD",
        "financial_status" => "paid", "fulfillment_status" => "unfulfilled",
        "created_at" => "2026-04-15T10:00:00Z",
        "customer" => shopify_customer,
        "shipping_address" => { "country_code" => "US" },
        "line_items" => [
          { "id" => 6001, "variant_id" => 8001, "sku" => "PK-BL", "title" => "Paint / Black",
            "quantity" => 1, "price" => "49.99" }
        ],
        "fulfillments" => [
          { "id" => 300, "status" => "success", "tracking_number" => "TRACK1",
            "tracking_company" => "USPS", "tracking_url" => "https://track.example.com" }
        ]
      }
    end

    before do
      store.update!(cost_fx_rate: 7.0, default_service_type: "with_battery")
    end

    it "sets estimated_shipping_cost after sync using the calculator (0.3 kg / US / April 2026 → 7.51)" do
      service.sync_single_order(shopify_order_with_weight)

      order = Order.find_by(shopify_order_id: 200)
      expect(order.estimated_shipping_cost).to eq(7.51)
    end

    it "does not overwrite estimated_shipping_cost on re-sync (frozen once set)" do
      service.sync_single_order(shopify_order_with_weight)

      order = Order.find_by(shopify_order_id: 200)
      order.update!(estimated_shipping_cost: 99.99)

      described_class.new(store).sync_single_order(shopify_order_with_weight)

      expect(order.reload.estimated_shipping_cost).to eq(99.99)
    end

    it "never sets actual_shipping_cost during sync" do
      service.sync_single_order(shopify_order_with_weight)

      order = Order.find_by(shopify_order_id: 200)
      expect(order.actual_shipping_cost).to be_nil
    end
  end
end
