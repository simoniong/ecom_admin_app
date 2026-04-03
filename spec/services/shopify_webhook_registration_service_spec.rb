require "rails_helper"

RSpec.describe ShopifyWebhookRegistrationService do
  let(:store) { create(:shopify_store) }
  let(:shopify_service) { instance_double(ShopifyService) }
  let(:service) { described_class.new(store) }

  before do
    allow(ShopifyService).to receive(:new).with(store).and_return(shopify_service)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("APP_HOST").and_return("https://app.example.com")
  end

  it "registers missing webhook topics" do
    allow(shopify_service).to receive(:list_webhooks).and_return({ "webhooks" => [] })
    allow(shopify_service).to receive(:register_webhook)

    service.call

    expect(shopify_service).to have_received(:register_webhook).with(
      topic: "orders/create", address: "https://app.example.com/shopify/webhooks"
    )
    expect(shopify_service).to have_received(:register_webhook).with(
      topic: "orders/updated", address: "https://app.example.com/shopify/webhooks"
    )
  end

  it "skips already registered topics" do
    allow(shopify_service).to receive(:list_webhooks).and_return({
      "webhooks" => [
        { "id" => 1, "topic" => "orders/create", "address" => "https://app.example.com/shopify/webhooks" }
      ]
    })
    allow(shopify_service).to receive(:register_webhook)

    service.call

    expect(shopify_service).to have_received(:register_webhook).once
    expect(shopify_service).to have_received(:register_webhook).with(
      topic: "orders/updated", address: "https://app.example.com/shopify/webhooks"
    )
  end

  it "deletes and re-registers webhook when address has changed" do
    allow(shopify_service).to receive(:list_webhooks).and_return({
      "webhooks" => [
        { "id" => 1, "topic" => "orders/create", "address" => "https://old-host.com/shopify/webhooks" },
        { "id" => 2, "topic" => "orders/updated", "address" => "https://app.example.com/shopify/webhooks" }
      ]
    })
    allow(shopify_service).to receive(:delete_webhook)
    allow(shopify_service).to receive(:register_webhook)

    service.call

    expect(shopify_service).to have_received(:delete_webhook).with(1)
    expect(shopify_service).to have_received(:register_webhook).with(
      topic: "orders/create", address: "https://app.example.com/shopify/webhooks"
    )
    expect(shopify_service).not_to have_received(:delete_webhook).with(2)
  end

  it "skips registration when APP_HOST is blank" do
    allow(ENV).to receive(:[]).with("APP_HOST").and_return(nil)
    allow(Rails.application.credentials).to receive(:dig).with(:app, :host).and_return(nil)

    service.call

    expect(store.reload.webhooks_registered_at).to be_nil
  end

  it "normalizes trailing slash in APP_HOST" do
    allow(ENV).to receive(:[]).with("APP_HOST").and_return("https://app.example.com/")
    allow(shopify_service).to receive(:list_webhooks).and_return({ "webhooks" => [] })
    allow(shopify_service).to receive(:register_webhook)

    service.call

    expect(shopify_service).to have_received(:register_webhook).with(
      topic: "orders/create", address: "https://app.example.com/shopify/webhooks"
    )
  end

  it "updates webhooks_registered_at on store" do
    allow(shopify_service).to receive(:list_webhooks).and_return({ "webhooks" => [] })
    allow(shopify_service).to receive(:register_webhook)

    freeze_time do
      service.call
      expect(store.reload.webhooks_registered_at).to eq(Time.current)
    end
  end
end
