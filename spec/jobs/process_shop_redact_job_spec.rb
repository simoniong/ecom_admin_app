require "rails_helper"

RSpec.describe ProcessShopRedactJob, type: :job do
  let(:store) { create(:shopify_store) }
  let!(:customer) { create(:customer, shopify_store: store) }
  let!(:order) { create(:order, customer: customer, shopify_store: store) }

  it "destroys the store and cascades customer/order cleanup" do
    expect {
      described_class.perform_now(store.id)
    }.to change(ShopifyStore, :count).by(-1)
      .and change(Customer, :count).by(-1)
      .and change(Order, :count).by(-1)
  end

  it "no-ops when the store does not exist" do
    expect {
      described_class.perform_now("00000000-0000-0000-0000-000000000000")
    }.not_to change(ShopifyStore, :count)
  end

  it "logs an error and swallows exceptions" do
    allow(Rails.logger).to receive(:error)
    allow_any_instance_of(ShopifyStoreDeletionService).to receive(:call).and_raise(StandardError.new("redact fail"))

    expect {
      described_class.perform_now(store.id)
    }.not_to raise_error

    expect(Rails.logger).to have_received(:error).with(/redact fail/)
  end
end
