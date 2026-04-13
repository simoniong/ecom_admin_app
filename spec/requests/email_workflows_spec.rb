require "rails_helper"

RSpec.describe "EmailWorkflows", type: :request do
  let(:user) { create(:user) }
  let(:shopify_store) { create(:shopify_store, user: user, company: user.companies.first) }

  before { sign_in user }

  describe "GET /shopify_stores/:store_id/email_workflows" do
    it "returns success" do
      get shopify_store_email_workflows_path(shopify_store_id: shopify_store.id)
      expect(response).to have_http_status(:success)
    end

    it "lists workflows for the store" do
      create(:email_workflow, shopify_store: shopify_store, trigger_event: "order_shipped")
      get shopify_store_email_workflows_path(shopify_store_id: shopify_store.id)
      expect(response.body).to include(I18n.t("email_workflows.trigger_events.order_shipped"))
    end

    it "redirects unauthenticated users" do
      sign_out user
      get shopify_store_email_workflows_path(shopify_store_id: shopify_store.id)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /shopify_stores/:store_id/email_workflows/new" do
    it "returns success" do
      get new_shopify_store_email_workflow_path(shopify_store_id: shopify_store.id)
      expect(response).to have_http_status(:success)
    end
  end

  describe "POST /shopify_stores/:store_id/email_workflows" do
    it "creates a workflow" do
      expect {
        post shopify_store_email_workflows_path(shopify_store_id: shopify_store.id), params: {
          email_workflow: { trigger_event: "order_shipped" }
        }
      }.to change(EmailWorkflow, :count).by(1)
    end

    it "redirects to edit on success" do
      post shopify_store_email_workflows_path(shopify_store_id: shopify_store.id), params: {
        email_workflow: { trigger_event: "order_shipped" }
      }
      workflow = EmailWorkflow.last
      expect(response).to redirect_to(edit_shopify_store_email_workflow_path(shopify_store_id: shopify_store.id, id: workflow.id))
    end

    it "renders new on invalid params" do
      post shopify_store_email_workflows_path(shopify_store_id: shopify_store.id), params: {
        email_workflow: { trigger_event: "" }
      }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /shopify_stores/:store_id/email_workflows/:id/edit" do
    let!(:workflow) { create(:email_workflow, shopify_store: shopify_store) }

    it "returns success" do
      get edit_shopify_store_email_workflow_path(shopify_store_id: shopify_store.id, id: workflow.id)
      expect(response).to have_http_status(:success)
    end

    it "shows the workflow editor" do
      get edit_shopify_store_email_workflow_path(shopify_store_id: shopify_store.id, id: workflow.id)
      expect(response.body).to include(I18n.t("email_workflows.trigger_events.#{workflow.trigger_event}"))
    end
  end

  describe "PATCH /shopify_stores/:store_id/email_workflows/:id" do
    let!(:workflow) { create(:email_workflow, shopify_store: shopify_store, enabled: true) }

    it "updates the workflow" do
      patch shopify_store_email_workflow_path(shopify_store_id: shopify_store.id, id: workflow.id), params: {
        email_workflow: { enabled: false }
      }
      expect(workflow.reload.enabled).to be false
    end

    it "redirects to index on success" do
      patch shopify_store_email_workflow_path(shopify_store_id: shopify_store.id, id: workflow.id), params: {
        email_workflow: { enabled: true }
      }
      expect(response).to redirect_to(shopify_store_email_workflows_path(shopify_store_id: shopify_store.id))
    end
  end

  describe "DELETE /shopify_stores/:store_id/email_workflows/:id" do
    let!(:workflow) { create(:email_workflow, shopify_store: shopify_store) }

    it "destroys the workflow" do
      expect {
        delete shopify_store_email_workflow_path(shopify_store_id: shopify_store.id, id: workflow.id)
      }.to change(EmailWorkflow, :count).by(-1)
    end

    it "redirects to index" do
      delete shopify_store_email_workflow_path(shopify_store_id: shopify_store.id, id: workflow.id)
      expect(response).to redirect_to(shopify_store_email_workflows_path(shopify_store_id: shopify_store.id))
    end
  end
end
