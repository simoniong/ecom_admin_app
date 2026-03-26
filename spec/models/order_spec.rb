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

  it "enforces shopify_order_id uniqueness" do
    create(:order, shopify_order_id: 99999)
    duplicate = build(:order, shopify_order_id: 99999)
    expect(duplicate).not_to be_valid
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
end
