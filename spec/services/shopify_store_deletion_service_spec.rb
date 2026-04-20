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

  it "deletes orders linked via shopify_store_id even when the customer belongs to another store" do
    other_store = create(:shopify_store)
    other_customer = create(:customer, shopify_store: other_store)
    cross_linked_order = create(:order, shopify_store: store, customer: other_customer)

    described_class.new(store).call

    expect(Order.exists?(cross_linked_order.id)).to be false
    # Orders + customer from the other store must be preserved
    expect(Customer.exists?(other_customer.id)).to be true
  end

  it "cleans up email_workflow_runs tied to orders before deleting the store" do
    workflow = create(:email_workflow, shopify_store: store)
    run_ticket = create(:ticket, email_account: email_account, customer: customer)
    workflow_run = create(:email_workflow_run, email_workflow: workflow, order: order, ticket: run_ticket)

    expect {
      described_class.new(store).call
    }.to change(EmailWorkflowRun, :count).by(-1)
      .and change(ShopifyStore, :count).by(-1)

    expect(EmailWorkflowRun.exists?(workflow_run.id)).to be false
  end
end
