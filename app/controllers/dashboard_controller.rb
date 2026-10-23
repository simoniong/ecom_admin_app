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
      head :unprocessable_entity
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
      {
        store_ids: store_scope.pluck(:id),
        meta_ids: ad_scope.where(platform: "meta").pluck(:id),
        google_ids: ad_scope.where(platform: "google").pluck(:id),
        runs: create_placeholder_runs(store_scope, ad_scope)
      }
    end
  end

  def acquire_sync_advisory_lock
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT pg_advisory_xact_lock(hashtext(?))", "dashboard_sync:#{current_company.id}" ]
      )
    )
  end

  # One placeholder per unit per source it will run under, so the badge goes
  # yellow the instant Sync is clicked. SyncRun#track (Task 1) deletes these
  # once the matching job actually starts, which closes the double-click race
  # without this request having to wait on the jobs themselves.
  def create_placeholder_runs(store_scope, ad_scope)
    now = Time.current
    runs = []

    store_scope.find_each do |store|
      runs << SyncRun.create!(source: "shopify_metrics", target: store, company_id: current_company.id,
                               trigger: "manual", status: "running", started_at: now)
      runs << SyncRun.create!(source: "shopify_orders", target: store, company_id: current_company.id,
                               trigger: "manual", status: "running", started_at: now)
    end

    ad_scope.where(platform: "meta").find_each do |account|
      runs << SyncRun.create!(source: "meta_ads", target: account, company_id: current_company.id,
                               trigger: "manual", status: "running", started_at: now)
    end

    ad_scope.where(platform: "google").find_each do |account|
      runs << SyncRun.create!(source: "google_ads", target: account, company_id: current_company.id,
                               trigger: "manual", status: "running", started_at: now)
    end

    runs
  end

  # Enqueues after the placeholder transaction has committed, so the jobs
  # never see rows a rolled-back transaction removed. If enqueueing raises
  # partway through, the placeholders this request created would otherwise
  # sit as "running" until they go stale; delete them and re-raise so the
  # failure is still visible (same job-error handling callers already expect).
  def enqueue_sync_jobs(sync_plan)
    store_ids = sync_plan[:store_ids]
    meta_ids = sync_plan[:meta_ids]
    google_ids = sync_plan[:google_ids]

    SyncShopifyMetricsJob.perform_later(store_ids: store_ids, trigger: "manual") if store_ids.any?
    store_ids.each { |store_id| SyncAllShopifyOrdersJob.perform_later(store_id, trigger: "manual") }
    SyncAdMetricsJob.perform_later(ad_account_ids: meta_ids, trigger: "manual") if meta_ids.any?
    SyncGoogleAdMetricsJob.perform_later(ad_account_ids: google_ids, trigger: "manual") if google_ids.any?
  rescue StandardError
    SyncRun.where(id: sync_plan[:runs].map(&:id)).delete_all
    raise
  end

  def sync_redirect_params
    { range: params[:range], start_date: params[:start_date], end_date: params[:end_date] }
  end
end
