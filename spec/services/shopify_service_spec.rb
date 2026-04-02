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

  describe "#fetch_all_orders" do
    it "returns all orders with pagination params" do
      stub_request(:get, "#{base_url}/orders.json")
        .with(query: { status: "any", limit: 250, order: "id asc" })
        .to_return(
          status: 200,
          body: { orders: [ { id: 456, name: "#1001" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.fetch_all_orders
      expect(result.length).to eq(1)
      expect(result.first["name"]).to eq("#1001")
    end

    it "passes since_id for pagination" do
      stub_request(:get, "#{base_url}/orders.json")
        .with(query: { status: "any", limit: 250, order: "id asc", since_id: 100 })
        .to_return(
          status: 200,
          body: { orders: [ { id: 200, name: "#1002" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.fetch_all_orders(since_id: 100)
      expect(result.first["id"]).to eq(200)
    end
  end

  describe "#fetch_all_customers" do
    it "returns all customers" do
      stub_request(:get, "#{base_url}/customers.json")
        .with(query: { limit: 250, order: "id asc" })
        .to_return(
          status: 200,
          body: { customers: [ { id: 100, email: "buyer@example.com" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.fetch_all_customers
      expect(result.length).to eq(1)
      expect(result.first["email"]).to eq("buyer@example.com")
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

  describe "#fetch_all_orders with updated_at_min" do
    it "passes updated_at_min as ISO8601" do
      time = Time.utc(2026, 4, 1, 12, 0, 0)
      stub_request(:get, "#{base_url}/orders.json")
        .with(query: { status: "any", limit: 250, order: "id asc", updated_at_min: time.iso8601 })
        .to_return(
          status: 200,
          body: { orders: [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.fetch_all_orders(updated_at_min: time)
      expect(result).to eq([])
    end
  end

  describe "#register_webhook" do
    it "posts webhook registration" do
      stub_request(:post, "#{base_url}/webhooks.json")
        .with(body: { webhook: { topic: "orders/create", address: "https://app.example.com/shopify/webhooks", format: "json" } })
        .to_return(
          status: 201,
          body: { webhook: { id: 1, topic: "orders/create" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.register_webhook(topic: "orders/create", address: "https://app.example.com/shopify/webhooks")
      expect(result["webhook"]["topic"]).to eq("orders/create")
    end
  end

  describe "#list_webhooks" do
    it "returns registered webhooks" do
      stub_request(:get, "#{base_url}/webhooks.json")
        .to_return(
          status: 200,
          body: { webhooks: [ { id: 1, topic: "orders/create" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.list_webhooks
      expect(result["webhooks"].length).to eq(1)
    end
  end

  describe "#delete_webhook" do
    it "deletes a webhook" do
      stub_request(:delete, "#{base_url}/webhooks/1.json")
        .to_return(
          status: 200,
          body: {}.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect { service.delete_webhook(1) }.not_to raise_error
    end
  end

  it "raises on API error" do
    stub_request(:get, "#{base_url}/customers/search.json")
      .with(query: { query: "email:fail@example.com" })
      .to_return(status: 500, body: "Internal Server Error")

    expect { service.find_customers_by_email("fail@example.com") }.to raise_error(RuntimeError, /Shopify API error/)
  end
end
