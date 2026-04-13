require "rails_helper"

RSpec.describe EmailWorkflowTriggerService do
  let(:shopify_store) { create(:shopify_store) }
  let(:email_account) { create(:email_account, shopify_store: shopify_store, user: shopify_store.user, company: shopify_store.company) }
  let(:customer) { create(:customer, shopify_store: shopify_store) }
  let(:order) { create(:order, customer: customer, shopify_store: shopify_store) }
  let!(:ticket) { create(:ticket, email_account: email_account, customer: customer, created_at: 1.hour.ago) }
  let!(:workflow) do
    create(:email_workflow, shopify_store: shopify_store, trigger_event: "order_shipped", enabled: true)
  end
  let!(:step) do
    create(:email_workflow_step, :send_email, email_workflow: workflow, position: 0)
  end

  describe ".check" do
    it "creates a workflow run and enqueues step job" do
      expect {
        described_class.check("order_shipped", order)
      }.to change(EmailWorkflowRun, :count).by(1)
        .and have_enqueued_job(EmailWorkflowStepJob)
    end

    it "sets correct attributes on the run" do
      described_class.check("order_shipped", order)
      run = EmailWorkflowRun.last
      expect(run.email_workflow).to eq(workflow)
      expect(run.order).to eq(order)
      expect(run.ticket).to eq(ticket)
      expect(run.status).to eq("running")
      expect(run.started_at).to be_present
    end

    it "does nothing when no matching workflow exists" do
      expect {
        described_class.check("order_placed", order)
      }.not_to change(EmailWorkflowRun, :count)
    end

    it "does nothing when workflow is disabled" do
      workflow.update!(enabled: false)
      expect {
        described_class.check("order_shipped", order)
      }.not_to change(EmailWorkflowRun, :count)
    end

    it "does nothing when workflow has no steps" do
      step.destroy!
      expect {
        described_class.check("order_shipped", order)
      }.not_to change(EmailWorkflowRun, :count)
    end

    it "does nothing when customer has no tickets" do
      ticket.destroy!
      expect {
        described_class.check("order_shipped", order)
      }.not_to change(EmailWorkflowRun, :count)
    end

    it "does nothing when order has no shopify_store" do
      order.update_column(:shopify_store_id, nil)
      expect {
        described_class.check("order_shipped", order.reload)
      }.not_to change(EmailWorkflowRun, :count)
    end

    it "picks the most recent ticket" do
      older_ticket = create(:ticket, email_account: email_account, customer: customer, created_at: 2.hours.ago)
      described_class.check("order_shipped", order)
      run = EmailWorkflowRun.last
      expect(run.ticket).to eq(ticket) # more recent
    end

    it "prevents duplicate runs for same workflow+order" do
      described_class.check("order_shipped", order)
      expect {
        described_class.check("order_shipped", order)
      }.not_to change(EmailWorkflowRun, :count)
    end
  end
end
