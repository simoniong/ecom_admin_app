class EmailWorkflowStepsController < AdminController
  before_action :set_shopify_store
  before_action :set_workflow
  before_action :set_step, only: [ :update, :destroy, :move ]

  def create
    max_position = @workflow.email_workflow_steps.maximum(:position) || -1
    @step = @workflow.email_workflow_steps.new(
      step_type: params[:step_type],
      position: max_position + 1,
      config: default_config(params[:step_type])
    )

    if @step.save
      @steps = @workflow.email_workflow_steps.order(:position)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to edit_shopify_store_email_workflow_path(@shopify_store, @workflow) }
      end
    else
      head :unprocessable_entity
    end
  end

  def update
    if @step.update(step_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to edit_shopify_store_email_workflow_path(@shopify_store, @workflow) }
      end
    else
      head :unprocessable_entity
    end
  end

  def destroy
    @step.destroy!
    reindex_positions!
    @steps = @workflow.email_workflow_steps.order(:position)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to edit_shopify_store_email_workflow_path(@shopify_store, @workflow) }
    end
  end

  def move
    new_position = params[:position].to_i
    old_position = @step.position

    if new_position != old_position
      @workflow.email_workflow_steps.where(position: new_position).update_all(position: old_position)
      @step.update!(position: new_position)
      reindex_positions!
    end

    @steps = @workflow.email_workflow_steps.order(:position)
    respond_to do |format|
      format.turbo_stream { render :create }
      format.html { redirect_to edit_shopify_store_email_workflow_path(@shopify_store, @workflow) }
    end
  end

  private

  def set_shopify_store
    @shopify_store = visible_shopify_stores.find(params[:shopify_store_id])
  end

  def set_workflow
    @workflow = @shopify_store.email_workflows.find(params[:email_workflow_id])
  end

  def set_step
    @step = @workflow.email_workflow_steps.find(params[:id])
  end

  def step_params
    params.require(:email_workflow_step).permit(
      :step_type,
      config: [ :amount, :unit, :instruction, :until_time, { only_days: [] } ]
    )
  end

  def default_config(step_type)
    case step_type
    when "delay"
      { "amount" => 1, "unit" => "days" }
    when "send_email"
      { "instruction" => "" }
    else
      {}
    end
  end

  def reindex_positions!
    @workflow.email_workflow_steps.order(:position, :created_at).each_with_index do |step, i|
      step.update_column(:position, i)
    end
  end
end
