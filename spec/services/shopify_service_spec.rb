require "rails_helper"

RSpec.describe ShopifyService do
  let(:store) { OpenStruct.new(shop_domain: "test-store.myshopify.com", access_token: "shpat_test") }
  let(:service) { described_class.new(store) }
  let(:base_url) { "https://test-store.myshopify.com/admin/api/2024-10" }

  describe "#find_customers_by_email" do
    it "returns customers matching email" do
      stub_request(:get, "#{base_url}/customers/search.json")
        .with(query: { query: "email:customer@example.com" })
        .to_return(
          status: 200,
          body: { customers: [ { id: 123, email: "customer@example.com" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.find_customers_by_email("customer@example.com")
      expect(result.length).to eq(1)
      expect(result.first["id"]).to eq(123)
    end

    it "returns empty array when no match" do
      stub_request(:get, "#{base_url}/customers/search.json")
        .with(query: { query: "email:nobody@example.com" })
        .to_return(
          status: 200,
          body: { customers: [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.find_customers_by_email("nobody@example.com")
      expect(result).to be_empty
    end
  end

  describe "#fetch_orders" do
    it "returns orders for customer" do
      stub_request(:get, "#{base_url}/customers/123/orders.json")
        .with(query: { status: "any", limit: 10 })
        .to_return(
          status: 200,
          body: { orders: [ { id: 456, name: "#1001" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.fetch_orders(123)
      expect(result.length).to eq(1)
      expect(result.first["name"]).to eq("#1001")
    end
  end

  describe "#fetch_fulfillments" do
    it "returns fulfillments for order" do
      stub_request(:get, "#{base_url}/orders/456/fulfillments.json")
        .to_return(
          status: 200,
          body: { fulfillments: [ { id: 789, tracking_number: "TRACK1" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.fetch_fulfillments(456)
      expect(result.length).to eq(1)
      expect(result.first["tracking_number"]).to eq("TRACK1")
    end
  end

  it "raises on API error" do
    stub_request(:get, "#{base_url}/customers/search.json")
      .with(query: { query: "email:fail@example.com" })
      .to_return(status: 500, body: "Internal Server Error")

    expect { service.find_customers_by_email("fail@example.com") }.to raise_error(RuntimeError, /Shopify API error/)
  end
end
