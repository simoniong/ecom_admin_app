require "rails_helper"

RSpec.describe RegisterShopifyWebhooksJob, type: :job do
  it "calls the registration service" do
    store = create(:shopify_store)
    service = instance_double(ShopifyWebhookRegistrationService)
    allow(ShopifyWebhookRegistrationService).to receive(:new).with(store).and_return(service)
    allow(service).to receive(:call)

    described_class.perform_now(store.id)

    expect(service).to have_received(:call)
  end

  it "does nothing when store not found" do
    expect(ShopifyWebhookRegistrationService).not_to receive(:new)
    described_class.perform_now("nonexistent-id")
  end

  it "handles errors gracefully" do
    store = create(:shopify_store)
    allow(ShopifyWebhookRegistrationService).to receive(:new).and_raise(RuntimeError, "API error")

    expect { described_class.perform_now(store.id) }.not_to raise_error
  end
end
