require "rails_helper"

RSpec.describe ProcessCustomerRedactJob, type: :job do
  let(:store) { create(:shopify_store) }
  let!(:customer) { create(:customer, shopify_store: store, shopify_customer_id: "9001", email: "gdpr@example.com") }
  let!(:ticket) { create(:ticket, customer: customer) }

  it "deletes the customer matched by shopify_customer_id and nullifies related tickets" do
    payload = { "customer" => { "id" => 9001, "email" => "gdpr@example.com" } }

    expect {
      described_class.perform_now(store.id, payload)
    }.to change(Customer, :count).by(-1)

    expect(ticket.reload.customer_id).to be_nil
  end

  it "falls back to email lookup when shopify_customer_id is missing" do
    payload = { "customer" => { "email" => "gdpr@example.com" } }

    expect {
      described_class.perform_now(store.id, payload)
    }.to change(Customer, :count).by(-1)
  end

  it "no-ops when payload has no customer identifiers" do
    payload = { "customer" => {} }

    expect {
      described_class.perform_now(store.id, payload)
    }.not_to change(Customer, :count)
  end

  it "no-ops when the store does not exist" do
    payload = { "customer" => { "id" => 9001 } }

    expect {
      described_class.perform_now("00000000-0000-0000-0000-000000000000", payload)
    }.not_to change(Customer, :count)
  end

  it "does not delete customers that belong to other stores" do
    other_store = create(:shopify_store)
    other_customer = create(:customer, shopify_store: other_store, shopify_customer_id: "9001", email: "gdpr@example.com")

    described_class.perform_now(store.id, { "customer" => { "id" => 9001 } })

    expect(Customer.exists?(other_customer.id)).to be true
  end

  it "logs an error and swallows exceptions" do
    allow(Rails.logger).to receive(:error)
    allow(ShopifyStore).to receive(:find_by).and_raise(StandardError.new("boom"))

    expect {
      described_class.perform_now(store.id, { "customer" => { "id" => 1 } })
    }.not_to raise_error

    expect(Rails.logger).to have_received(:error).with(/boom/)
  end
end
