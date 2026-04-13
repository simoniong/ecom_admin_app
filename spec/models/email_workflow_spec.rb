require "rails_helper"

RSpec.describe EmailWorkflow, type: :model do
  let(:shopify_store) { create(:shopify_store) }
  let(:workflow) { create(:email_workflow, shopify_store: shopify_store) }

  it "is valid with valid attributes" do
    expect(workflow).to be_valid
  end

  it "generates a UUID id" do
    expect(workflow.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to shopify_store" do
    expect(workflow.shopify_store).to eq(shopify_store)
  end

  it "requires trigger_event" do
    workflow.trigger_event = nil
    expect(workflow).not_to be_valid
  end

  it "validates trigger_event inclusion" do
    workflow.trigger_event = "invalid_event"
    expect(workflow).not_to be_valid
  end

  it "accepts valid trigger_events" do
    %w[order_placed order_shipped order_delivered].each do |event|
      workflow.trigger_event = event
      expect(workflow).to be_valid
    end
  end

  it "enforces uniqueness of trigger_event per shopify_store" do
    create(:email_workflow, shopify_store: shopify_store, trigger_event: "order_placed")
    duplicate = build(:email_workflow, shopify_store: shopify_store, trigger_event: "order_placed")
    expect(duplicate).not_to be_valid
  end

  it "allows same trigger_event for different stores" do
    other_store = create(:shopify_store)
    workflow1 = create(:email_workflow, shopify_store: shopify_store, trigger_event: "order_placed")
    workflow2 = build(:email_workflow, shopify_store: other_store, trigger_event: "order_placed")
    expect(workflow2).to be_valid
  end

  it "defaults to enabled" do
    new_workflow = EmailWorkflow.new
    expect(new_workflow.enabled).to be true
  end

  it "has many email_workflow_steps ordered by position" do
    step2 = create(:email_workflow_step, email_workflow: workflow, position: 1)
    step1 = create(:email_workflow_step, email_workflow: workflow, position: 0)
    expect(workflow.email_workflow_steps).to eq([ step1, step2 ])
  end

  it "destroys associated steps when destroyed" do
    create(:email_workflow_step, email_workflow: workflow)
    expect { workflow.destroy! }.to change(EmailWorkflowStep, :count).by(-1)
  end

  it "has many email_workflow_runs" do
    expect(workflow).to respond_to(:email_workflow_runs)
  end

  describe ".enabled" do
    it "returns only enabled workflows" do
      enabled = create(:email_workflow, shopify_store: shopify_store, trigger_event: "order_placed", enabled: true)
      create(:email_workflow, shopify_store: shopify_store, trigger_event: "order_delivered", enabled: false)
      expect(EmailWorkflow.enabled).to eq([ enabled ])
    end
  end

  describe "#trigger_event_display" do
    it "returns titleized trigger event" do
      workflow.trigger_event = "order_shipped"
      expect(workflow.trigger_event_display).to eq("Order Shipped")
    end
  end
end
