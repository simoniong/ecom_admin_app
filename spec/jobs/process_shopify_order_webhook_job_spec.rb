require "rails_helper"

RSpec.describe ProcessShopifyOrderWebhookJob, type: :job do
  let(:store) { create(:shopify_store) }
  let(:order_payload) do
    {
      "id" => 200, "email" => "buyer@example.com", "name" => "#1001",
      "total_price" => "49.99", "currency" => "USD",
      "financial_status" => "paid", "fulfillment_status" => "fulfilled",
      "created_at" => "2026-03-20",
      "customer" => { "id" => 100, "email" => "buyer@example.com", "first_name" => "Jane" },
      "fulfillments" => []
    }
  end

  it "calls sync_single_order on the service" do
    service = instance_double(SyncAllOrdersService)
    allow(SyncAllOrdersService).to receive(:new).with(store).and_return(service)
    allow(service).to receive(:sync_single_order)

    described_class.perform_now(store.id, order_payload)

    expect(service).to have_received(:sync_single_order).with(order_payload)
  end

  it "does nothing when store not found" do
    expect(SyncAllOrdersService).not_to receive(:new)
    described_class.perform_now("nonexistent-id", order_payload)
  end

  it "handles errors gracefully" do
    service = instance_double(SyncAllOrdersService)
    allow(SyncAllOrdersService).to receive(:new).with(store).and_return(service)
    allow(service).to receive(:sync_single_order).and_raise(RuntimeError, "bad data")

    expect { described_class.perform_now(store.id, order_payload) }.not_to raise_error
  end
end
