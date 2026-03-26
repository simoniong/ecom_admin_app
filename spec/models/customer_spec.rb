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

  it "enforces shopify_customer_id uniqueness" do
    create(:customer, shopify_customer_id: 12345)
    duplicate = build(:customer, shopify_customer_id: 12345)
    expect(duplicate).not_to be_valid
  end

  it "has many orders with dependent destroy" do
    customer = create(:customer)
    create(:order, customer: customer)
    expect { customer.destroy }.to change(Order, :count).by(-1)
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
end
