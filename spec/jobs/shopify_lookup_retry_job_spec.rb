require "rails_helper"

RSpec.describe ShopifyLookupRetryJob do
  let(:store) { create(:shopify_store) }
  let(:email_account) { create(:email_account, shopify_store: store, user: store.user) }
  let(:ticket) { create(:ticket, email_account: email_account, customer_email: "buyer@example.com") }

  it "calls ShopifyLookupService for the ticket" do
    lookup = instance_double(ShopifyLookupService)
    allow(ShopifyLookupService).to receive(:new).and_return(lookup)
    allow(lookup).to receive(:lookup)

    described_class.perform_now(ticket.id)

    expect(lookup).to have_received(:lookup).with(ticket)
  end

  it "skips if ticket already has a customer" do
    customer = create(:customer, shopify_store: store, email: "buyer@example.com")
    ticket.update!(customer: customer)

    lookup = instance_double(ShopifyLookupService)
    allow(ShopifyLookupService).to receive(:new).and_return(lookup)
    allow(lookup).to receive(:lookup)

    described_class.perform_now(ticket.id)

    expect(lookup).not_to have_received(:lookup)
  end

  it "skips if ticket does not exist" do
    lookup = instance_double(ShopifyLookupService)
    allow(ShopifyLookupService).to receive(:new).and_return(lookup)
    allow(lookup).to receive(:lookup)

    described_class.perform_now("nonexistent-id")

    expect(lookup).not_to have_received(:lookup)
  end

  it "skips if customer_email is 'unknown'" do
    ticket.update_column(:customer_email, "unknown")

    lookup = instance_double(ShopifyLookupService)
    allow(ShopifyLookupService).to receive(:new).and_return(lookup)
    allow(lookup).to receive(:lookup)

    described_class.perform_now(ticket.id)

    expect(lookup).not_to have_received(:lookup)
  end

  it "skips if customer_email has no @" do
    ticket.update_column(:customer_email, "not-an-email")

    lookup = instance_double(ShopifyLookupService)
    allow(ShopifyLookupService).to receive(:new).and_return(lookup)
    allow(lookup).to receive(:lookup)

    described_class.perform_now(ticket.id)

    expect(lookup).not_to have_received(:lookup)
  end

  it "retries on failure" do
    lookup = instance_double(ShopifyLookupService)
    allow(ShopifyLookupService).to receive(:new).and_return(lookup)
    allow(lookup).to receive(:lookup).and_raise(RuntimeError, "API down")

    expect {
      described_class.perform_now(ticket.id)
    }.to have_enqueued_job(described_class).with(ticket.id)
  end
end
