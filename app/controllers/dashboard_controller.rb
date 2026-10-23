class DashboardController < AdminController
  def show
    @range_key = if params[:start_date].present? && params[:end_date].present?
                   "custom"
    elsif DashboardMetricsService::RANGES.key?(params[:range])
                   params[:range]
    else
                   "past_7_days"
    end

    metrics_scope = selected_view_group || current_company
    @metrics = DashboardMetricsService.new(
      metrics_scope,
      range_key: @range_key,
      start_date: params[:start_date],
      end_date: params[:end_date],
      shopify_store: current_shopify_store
    ).call
    @range_key = @metrics[:range_key]
    @current_view_group = selected_view_group
    @sync_status = sync_status_for_current_scope
  end

  def sync
    sync_plan = create_sync_placeholders_if_idle

    if sync_plan.nil?
      redirect_to authenticated_root_path(sync_redirect_params), alert: t("dashboard.sync.already_running")
      return
    end

    enqueue_sync_jobs(sync_plan)

    redirect_to authenticated_root_path(sync_redirect_params), notice: t("dashboard.sync.enqueued")
  end

  def sync_status
    render partial: "dashboard/sync_status",
           locals: { sync_status: sync_status_for_current_scope },
           layout: false
  end

  def acknowledge_sync
    source = params[:source].to_s

    unless SyncRun::SOURCES.include?(source)
      head :unprocessable_content
      return
    end

    status = sync_status_for_current_scope
    current_source = status.sources.find { |candidate| candidate.key == source }

    # A source with no current failure has no signature to acknowledge
    # against (sync_acknowledgements.signature is NOT NULL) — silently no-op
    # and re-render instead of writing a meaningless acknowledgement.
    status.acknowledge!(source) if current_source&.signature.present?

    render partial: "dashboard/sync_status", locals: { sync_status: status }, layout: false
  end

  private

  def sync_status_for_current_scope
    store_scope, ad_scope = dashboard_scopes
    SyncStatus.new(company: current_company, store_scope: store_scope, ad_scope: ad_scope, user: current_user)
  end

  def dashboard_scopes
    DashboardMetricsService.scopes_for(selected_view_group || current_company, current_shopify_store)
  end

  # Serializes the running?-check/placeholder-create transition per company:
  # takes a Postgres transaction-level advisory lock scoped to the company
  # before checking, so two overlapping requests can't both see nothing
  # running and both enqueue. Returns nil (do nothing) if a run in scope is
  # already running, otherwise the ids to enqueue plus the placeholder rows
  # this request created, once the transaction has committed.
  def create_sync_placeholders_if_idle
    ActiveRecord::Base.transaction do
      acquire_sync_advisory_lock

      next nil if sync_status_for_current_scope.running?

      store_scope, ad_scope = dashboard_scopes
      plan = {
        batch_id: SecureRandom.uuid,
        store_ids: store_scope.pluck(:id),
        meta_ids: ad_scope.where(platform: "meta").pluck(:id),
        google_ids: ad_scope.where(platform: "google").pluck(:id)
      }
      plan.merge(placeholders: create_placeholder_runs(plan))
    end
  end

  def acquire_sync_advisory_lock
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT pg_advisory_xact_lock(hashtext(?))", "dashboard_sync:#{current_company.id}" ]
      )
    )
  end

  # One placeholder per unit per source it will run under, all tagged with this
  # click's batch id, so the badge goes yellow the instant Sync is clicked and
  # the job this request enqueues for that unit claims that exact row
  # (SyncRun.track) rather than racing it. Returns the row ids keyed by
  # [source, target_id], which is how enqueue_sync_jobs finds the placeholders
  # of the jobs it never got to enqueue.
  def create_placeholder_runs(plan)
    now = Time.current
    units = plan[:store_ids].flat_map do |store_id|
      [ [ "shopify_metrics", "ShopifyStore", store_id ], [ "shopify_orders", "ShopifyStore", store_id ] ]
    end
    units += plan[:meta_ids].map { |id| [ "meta_ads", "AdAccount", id ] }
    units += plan[:google_ids].map { |id| [ "google_ads", "AdAccount", id ] }

    units.to_h do |source, target_type, target_id|
      run = SyncRun.create!(source: source, target_type: target_type, target_id: target_id,
                            company_id: current_company.id, trigger: "manual", status: "running",
                            placeholder: true, batch_id: plan[:batch_id], started_at: now)
      [ [ source, target_id ], run.id ]
    end
  end

  # Enqueues after the placeholder transaction has committed, so the jobs never
  # see rows a rolled-back transaction removed. One job at a time: an enqueue
  # that raises leaves the jobs already on the queue alone — they are real work
  # now and their placeholders are the only sign of it — and removes only the
  # placeholders of the jobs that never made it out before re-raising.
  def enqueue_sync_jobs(sync_plan)
    steps = sync_enqueue_steps(sync_plan)

    steps.each_with_index do |step, index|
      step[:enqueue].call
    rescue StandardError
      SyncRun.where(id: steps[index..].flat_map { |pending| pending[:run_ids] }).delete_all
      raise
    end
  end

  # Each step pairs one perform_later with the placeholders it is the only
  # thing that will ever report into, which is what makes a partial failure
  # recoverable row by row.
  def sync_enqueue_steps(sync_plan)
    placeholders = sync_plan[:placeholders]
    store_ids = sync_plan[:store_ids]
    meta_ids = sync_plan[:meta_ids]
    google_ids = sync_plan[:google_ids]
    batch = { trigger: "manual", sync_batch_id: sync_plan[:batch_id] }
    steps = []

    if store_ids.any?
      steps << { run_ids: store_ids.map { |id| placeholders[[ "shopify_metrics", id ]] },
                 enqueue: -> { SyncShopifyMetricsJob.perform_later(store_ids: store_ids, **batch) } }
    end

    store_ids.each do |store_id|
      steps << { run_ids: [ placeholders[[ "shopify_orders", store_id ]] ],
                 enqueue: -> { SyncAllShopifyOrdersJob.perform_later(store_id, **batch) } }
    end

    if meta_ids.any?
      steps << { run_ids: meta_ids.map { |id| placeholders[[ "meta_ads", id ]] },
                 enqueue: -> { SyncAdMetricsJob.perform_later(ad_account_ids: meta_ids, **batch) } }
    end

    if google_ids.any?
      steps << { run_ids: google_ids.map { |id| placeholders[[ "google_ads", id ]] },
                 enqueue: -> { SyncGoogleAdMetricsJob.perform_later(ad_account_ids: google_ids, **batch) } }
    end

    steps
  end

  def sync_redirect_params
    { range: params[:range], start_date: params[:start_date], end_date: params[:end_date] }
  end
end
