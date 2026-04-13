class EmailWorkflowsController < AdminController
  before_action :set_shopify_store
  before_action :set_workflow, only: [ :edit, :update, :destroy ]

  def index
    @workflows = @shopify_store.email_workflows.includes(:email_workflow_steps).order(:trigger_event)
  end

  def new
    @workflow = @shopify_store.email_workflows.new
    @available_events = available_trigger_events
  end

  def create
    @workflow = @shopify_store.email_workflows.new(workflow_params)

    if @workflow.save
      redirect_to edit_shopify_store_email_workflow_path(@shopify_store, @workflow),
                  notice: t("email_workflows.created")
    else
      @available_events = available_trigger_events
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @steps = @workflow.email_workflow_steps.order(:position)
  end

  def update
    if @workflow.update(workflow_params)
      redirect_to shopify_store_email_workflows_path(@shopify_store),
                  notice: t("email_workflows.updated")
    else
      @steps = @workflow.email_workflow_steps.order(:position)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @workflow.destroy!
    redirect_to shopify_store_email_workflows_path(@shopify_store),
                notice: t("email_workflows.deleted")
  end

  private

  def set_shopify_store
    @shopify_store = current_company.shopify_stores.find(params[:shopify_store_id])
  end

  def set_workflow
    @workflow = @shopify_store.email_workflows.find(params[:id])
  end

  def workflow_params
    params.require(:email_workflow).permit(:trigger_event, :enabled)
  end

  def available_trigger_events
    used = @shopify_store.email_workflows.where.not(id: @workflow&.id).pluck(:trigger_event)
    EmailWorkflow::TRIGGER_EVENTS - used
  end
end
