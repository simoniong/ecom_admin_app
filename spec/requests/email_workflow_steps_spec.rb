require "rails_helper"

RSpec.describe "EmailWorkflowSteps", type: :request do
  let(:user) { create(:user) }
  let(:shopify_store) { create(:shopify_store, user: user, company: user.companies.first) }
  let(:workflow) { create(:email_workflow, shopify_store: shopify_store) }

  before { sign_in user }

  def steps_path
    shopify_store_email_workflow_email_workflow_steps_path(
      shopify_store_id: shopify_store.id,
      email_workflow_id: workflow.id
    )
  end

  def step_path(step)
    shopify_store_email_workflow_email_workflow_step_path(
      shopify_store_id: shopify_store.id,
      email_workflow_id: workflow.id,
      id: step.id
    )
  end

  def move_path(step)
    move_shopify_store_email_workflow_email_workflow_step_path(
      shopify_store_id: shopify_store.id,
      email_workflow_id: workflow.id,
      id: step.id
    )
  end

  describe "POST create" do
    it "creates a delay step" do
      expect {
        post steps_path, params: { step_type: "delay" },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
      }.to change(EmailWorkflowStep, :count).by(1)

      step = EmailWorkflowStep.last
      expect(step.step_type).to eq("delay")
      expect(step.config["amount"]).to eq(1)
    end

    it "creates a send_email step" do
      expect {
        post steps_path, params: { step_type: "send_email" },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
      }.to change(EmailWorkflowStep, :count).by(1)

      step = EmailWorkflowStep.last
      expect(step.step_type).to eq("send_email")
    end

    it "auto-increments position" do
      create(:email_workflow_step, email_workflow: workflow, position: 0)
      post steps_path, params: { step_type: "delay" },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(EmailWorkflowStep.last.position).to eq(1)
    end
  end

  describe "PATCH update" do
    let!(:step) { create(:email_workflow_step, :delay, email_workflow: workflow, position: 0) }

    it "updates step config" do
      patch step_path(step),
            params: { email_workflow_step: { config: { amount: 3, unit: "days" } } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      step.reload
      expect(step.config["amount"]).to eq("3")
      expect(step.config["unit"]).to eq("days")
    end
  end

  describe "DELETE destroy" do
    let!(:step) { create(:email_workflow_step, email_workflow: workflow, position: 0) }

    it "destroys the step" do
      expect {
        delete step_path(step), headers: { "Accept" => "text/vnd.turbo-stream.html" }
      }.to change(EmailWorkflowStep, :count).by(-1)
    end

    it "reindexes positions" do
      step2 = create(:email_workflow_step, email_workflow: workflow, position: 1)
      delete step_path(step), headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(step2.reload.position).to eq(0)
    end
  end

  describe "POST move" do
    let!(:step1) { create(:email_workflow_step, email_workflow: workflow, position: 0) }
    let!(:step2) { create(:email_workflow_step, email_workflow: workflow, position: 1) }

    it "swaps step positions" do
      post move_path(step1), params: { position: 1 },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(step1.reload.position).to eq(1)
      expect(step2.reload.position).to eq(0)
    end
  end
end
