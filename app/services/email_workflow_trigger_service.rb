class EmailWorkflowTriggerService
  def self.check(trigger_event, order)
    store = order.shopify_store
    return unless store

    workflow = EmailWorkflow.find_by(shopify_store: store, trigger_event: trigger_event, enabled: true)
    return unless workflow
    return unless workflow.email_workflow_steps.exists?

    customer = order.customer
    return unless customer

    ticket = customer.tickets.where("tickets.created_at < ?", Time.current).order(created_at: :desc).first
    return unless ticket

    run = EmailWorkflowRun.create!(
      email_workflow: workflow,
      order: order,
      ticket: ticket,
      status: "running",
      started_at: Time.current
    )

    EmailWorkflowStepJob.perform_later(run.id)
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("[EmailWorkflowTrigger] Duplicate run skipped: workflow=#{trigger_event} order=#{order.id}")
  end
end
