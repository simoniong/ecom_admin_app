module EmailWorkflowsHelper
  def available_trigger_events(shopify_store)
    used = shopify_store.email_workflows.pluck(:trigger_event)
    EmailWorkflow::TRIGGER_EVENTS - used
  end
end
