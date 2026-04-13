require "rails_helper"

RSpec.describe EmailWorkflowRun, type: :model do
  let(:workflow) { create(:email_workflow) }
  let(:order) { create(:order) }
  let(:ticket) { create(:ticket) }
  let(:run) { create(:email_workflow_run, email_workflow: workflow, order: order, ticket: ticket) }

  it "is valid with valid attributes" do
    expect(run).to be_valid
  end

  it "belongs to email_workflow" do
    expect(run.email_workflow).to eq(workflow)
  end

  it "belongs to order" do
    expect(run.order).to eq(order)
  end

  it "belongs to ticket" do
    expect(run.ticket).to eq(ticket)
  end

  it "requires started_at" do
    run.started_at = nil
    expect(run).not_to be_valid
  end

  it "validates status inclusion" do
    run.status = "invalid"
    expect(run).not_to be_valid
  end

  it "validates cancelled_reason inclusion" do
    run.cancelled_reason = "invalid"
    expect(run).not_to be_valid
  end

  it "allows nil cancelled_reason" do
    run.cancelled_reason = nil
    expect(run).to be_valid
  end

  it "defaults to running status" do
    new_run = EmailWorkflowRun.new
    expect(new_run.status).to eq("running")
  end

  describe "status methods" do
    it "returns true for running?" do
      run.status = "running"
      expect(run.running?).to be true
    end

    it "returns true for completed?" do
      run.status = "completed"
      expect(run.completed?).to be true
    end

    it "returns true for cancelled?" do
      run.status = "cancelled"
      expect(run.cancelled?).to be true
    end
  end

  describe "#cancel!" do
    it "sets status to cancelled with reason" do
      run.cancel!("customer_replied")
      expect(run.reload.status).to eq("cancelled")
      expect(run.cancelled_reason).to eq("customer_replied")
      expect(run.completed_at).to be_present
    end
  end

  describe "#complete!" do
    it "sets status to completed" do
      run.complete!
      expect(run.reload.status).to eq("completed")
      expect(run.completed_at).to be_present
    end
  end

  describe ".running" do
    it "returns only running runs" do
      running = create(:email_workflow_run, email_workflow: workflow, order: order, ticket: ticket, status: "running")
      other_order = create(:order, customer: order.customer)
      create(:email_workflow_run, email_workflow: workflow, order: other_order, ticket: ticket, status: "completed", completed_at: Time.current)
      expect(EmailWorkflowRun.running).to eq([ running ])
    end
  end

  it "enforces uniqueness of email_workflow_id + order_id" do
    run # create first run
    duplicate = build(:email_workflow_run, email_workflow: workflow, order: order, ticket: ticket)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
