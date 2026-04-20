require "rails_helper"

RSpec.describe ShopifyStoreDeletionService do
  let(:store) { create(:shopify_store) }
  let!(:customer) { create(:customer, shopify_store: store) }
  let!(:order) { create(:order, customer: customer, shopify_store: store) }
  let(:email_account) { create(:email_account, company: store.company, user: store.user) }
  let!(:ticket) { create(:ticket, email_account: email_account, customer: customer) }

  it "destroys store, customers, and orders; nullifies tickets" do
    expect {
      described_class.new(store).call
    }.to change(ShopifyStore, :count).by(-1)
      .and change(Customer, :count).by(-1)
      .and change(Order, :count).by(-1)

    expect(ticket.reload.customer_id).to be_nil
  end

  it "deletes orders directly associated with the store when customer link is nil" do
    orphan_order = create(:order, shopify_store: store, customer: customer)
    described_class.new(store).call
    expect(Order.exists?(orphan_order.id)).to be false
  end
end
