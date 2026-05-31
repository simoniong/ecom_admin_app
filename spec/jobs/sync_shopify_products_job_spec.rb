require "rails_helper"

RSpec.describe SyncShopifyProductsJob do
  let(:store) { create(:shopify_store) }

  it "invokes SyncShopifyProductsService with the store" do
    service = instance_double(SyncShopifyProductsService, call: nil)
    expect(SyncShopifyProductsService).to receive(:new).with(an_instance_of(ShopifyStore)).and_return(service)
    described_class.new.perform(store.id)
  end
end
