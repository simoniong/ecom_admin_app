require "rails_helper"

RSpec.describe Order, type: :model do
  it "is valid with valid attributes" do
    order = build(:order)
    expect(order).to be_valid
  end

  it "requires shopify_order_id" do
    order = build(:order, shopify_order_id: nil)
    expect(order).not_to be_valid
  end

  it "enforces shopify_order_id uniqueness within store" do
    store = create(:shopify_store)
    customer = create(:customer, shopify_store: store)
    create(:order, customer: customer, shopify_store: store, shopify_order_id: 99999)
    duplicate = build(:order, customer: customer, shopify_store: store, shopify_order_id: 99999)
    expect(duplicate).not_to be_valid
  end

  it "allows same shopify_order_id across different stores" do
    store1 = create(:shopify_store)
    store2 = create(:shopify_store)
    customer1 = create(:customer, shopify_store: store1)
    customer2 = create(:customer, shopify_store: store2)
    create(:order, customer: customer1, shopify_store: store1, shopify_order_id: 99999)
    other = build(:order, customer: customer2, shopify_store: store2, shopify_order_id: 99999)
    expect(other).to be_valid
  end

  it "belongs to customer" do
    order = create(:order)
    expect(order.customer).to be_a(Customer)
  end

  it "has many fulfillments with dependent destroy" do
    order = create(:order)
    create(:fulfillment, order: order)
    expect { order.destroy }.to change(Fulfillment, :count).by(-1)
  end

  it ".by_recency orders by ordered_at desc" do
    customer = create(:customer)
    old_order = create(:order, customer: customer, ordered_at: 5.days.ago)
    new_order = create(:order, customer: customer, ordered_at: 1.day.ago)
    expect(customer.orders.by_recency).to eq([ new_order, old_order ])
  end

  describe ".ordered_between" do
    it "returns orders within the date range" do
      customer = create(:customer)
      inside = create(:order, customer: customer, ordered_at: 2.days.ago)
      outside = create(:order, customer: customer, ordered_at: 10.days.ago)

      results = Order.ordered_between(3.days.ago.beginning_of_day, Time.current.end_of_day)
      expect(results).to include(inside)
      expect(results).not_to include(outside)
    end
  end

  describe ".search_by" do
    it "finds orders by email" do
      customer = create(:customer, email: "alice@example.com")
      order = create(:order, customer: customer, email: "alice@example.com")
      create(:order)

      expect(Order.search_by("alice")).to eq([ order ])
    end

    it "finds orders by customer name" do
      customer = create(:customer, first_name: "Jane", last_name: "Smith")
      order = create(:order, customer: customer)
      create(:order)

      expect(Order.search_by("Jane")).to eq([ order ])
    end

    it "finds orders by full name" do
      customer = create(:customer, first_name: "Jane", last_name: "Smith")
      order = create(:order, customer: customer)
      create(:order)

      expect(Order.search_by("Jane Smith")).to eq([ order ])
    end
  end

  describe ".by_financial_status" do
    it "filters by financial status" do
      customer = create(:customer)
      paid = create(:order, customer: customer, financial_status: "paid")
      pending = create(:order, customer: customer, financial_status: "pending")

      expect(Order.by_financial_status("paid")).to eq([ paid ])
    end
  end

  describe ".by_fulfillment_status" do
    it "filters by fulfillment status" do
      customer = create(:customer)
      fulfilled = create(:order, customer: customer, fulfillment_status: "fulfilled")
      unfulfilled = create(:order, customer: customer, fulfillment_status: nil)

      expect(Order.by_fulfillment_status("fulfilled")).to eq([ fulfilled ])
    end
  end

  describe "profit methods" do
    let(:order) { create(:order, total_price: 100) }

    it "#cogs_total sums quantity * unit_cost_snapshot" do
      create(:order_line_item, order: order, quantity: 2, unit_cost_snapshot: 10)
      create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: 5)
      expect(order.cogs_total).to eq(25)
    end

    it "#cogs_total treats null snapshots as 0" do
      create(:order_line_item, order: order, quantity: 2, unit_cost_snapshot: nil)
      create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: 5)
      expect(order.cogs_total).to eq(5)
    end

    it "#gross_profit = total_price - cogs_total" do
      create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: 30)
      expect(order.gross_profit).to eq(70)
    end

    it "#gross_profit returns nil when total_price is nil" do
      nil_order = create(:order, total_price: nil)
      expect(nil_order.gross_profit).to be_nil
    end

    it "#gross_margin_pct = gross_profit / total_price * 100" do
      create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: 30)
      expect(order.gross_margin_pct).to eq(70.0)
    end

    it "#gross_margin_pct returns nil when total_price is 0" do
      zero_order = create(:order, total_price: 0)
      expect(zero_order.gross_margin_pct).to be_nil
    end

    it "#gross_margin_pct returns nil when total_price is nil" do
      nil_order = create(:order, total_price: nil)
      expect(nil_order.gross_margin_pct).to be_nil
    end

    it "#cogs_complete? is true when all snapshots are set" do
      create(:order_line_item, order: order, unit_cost_snapshot: 1)
      expect(order.cogs_complete?).to be true
    end

    it "#cogs_complete? is false when any snapshot is null" do
      create(:order_line_item, order: order, unit_cost_snapshot: nil)
      expect(order.cogs_complete?).to be false
    end

    it "#cogs_complete? is true when there are no line items" do
      expect(order.cogs_complete?).to be true
    end
  end
end
