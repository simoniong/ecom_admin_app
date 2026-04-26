require "rails_helper"

RSpec.describe Customer, type: :model do
  it "is valid with valid attributes" do
    customer = build(:customer)
    expect(customer).to be_valid
  end

  it "requires shopify_customer_id" do
    customer = build(:customer, shopify_customer_id: nil)
    expect(customer).not_to be_valid
  end

  it "enforces shopify_customer_id uniqueness within store" do
    store = create(:shopify_store)
    create(:customer, shopify_store: store, shopify_customer_id: 12345)
    duplicate = build(:customer, shopify_store: store, shopify_customer_id: 12345)
    expect(duplicate).not_to be_valid
  end

  it "allows same shopify_customer_id across different stores" do
    store1 = create(:shopify_store)
    store2 = create(:shopify_store)
    create(:customer, shopify_store: store1, shopify_customer_id: 12345)
    other = build(:customer, shopify_store: store2, shopify_customer_id: 12345)
    expect(other).to be_valid
  end

  it "has many orders with dependent destroy" do
    customer = create(:customer)
    create(:order, customer: customer)
    expect { customer.destroy }.to change(Order, :count).by(-1)
  end

  it "nullifies tickets when destroyed instead of deleting them" do
    customer = create(:customer)
    ticket = create(:ticket, customer: customer)
    expect { customer.destroy }.not_to change(Ticket, :count)
    expect(ticket.reload.customer_id).to be_nil
  end

  describe "#full_name" do
    it "returns first and last name" do
      customer = build(:customer, first_name: "Jane", last_name: "Smith")
      expect(customer.full_name).to eq("Jane Smith")
    end

    it "returns first name only when last name is blank" do
      customer = build(:customer, first_name: "Jane", last_name: nil)
      expect(customer.full_name).to eq("Jane")
    end

    it "returns nil when both names are blank" do
      customer = build(:customer, first_name: nil, last_name: nil)
      expect(customer.full_name).to be_nil
    end
  end

  describe "#shipping_address" do
    it "returns the default_address hash from shopify_data" do
      address = { "address1" => "1 Main St", "city" => "Toronto", "country" => "Canada" }
      customer = build(:customer, shopify_data: { "default_address" => address })
      expect(customer.shipping_address).to eq(address)
    end

    it "returns nil when shopify_data has no default_address" do
      customer = build(:customer, shopify_data: {})
      expect(customer.shipping_address).to be_nil
    end

    it "returns nil when default_address is empty" do
      customer = build(:customer, shopify_data: { "default_address" => {} })
      expect(customer.shipping_address).to be_nil
    end
  end

  describe "#formatted_shipping_address" do
    it "joins address parts with commas, skipping blanks" do
      customer = build(:customer, shopify_data: {
        "default_address" => {
          "address1" => "1 Main St",
          "address2" => "",
          "city" => "Toronto",
          "province" => "ON",
          "zip" => "M5V 1A1",
          "country" => "Canada"
        }
      })
      expect(customer.formatted_shipping_address).to eq("1 Main St, Toronto, ON, M5V 1A1, Canada")
    end

    it "returns nil when no shipping address is set" do
      customer = build(:customer, shopify_data: {})
      expect(customer.formatted_shipping_address).to be_nil
    end
  end
end
