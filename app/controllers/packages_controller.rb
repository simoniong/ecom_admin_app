class PackagesController < AdminController
  PER_PAGE = 50
  STATES = %w[pending_review pending_process applying_tracking pending_label shipped refunded held].freeze
  APPLICATION_STATUSES = %w[pending succeeded failed].freeze
  REVIEW_EVENTS  = %w[submit_review back_to_review].freeze
  PROCESS_EVENTS = %w[hold unhold back_to_process].freeze

  # Shopify address keys this app persists on the snapshot. Full replace on
  # every save (rather than a merge) is fine — the edit form always submits
  # every key, and blank optionals should store "" (not silently keep a
  # stale prior value) so address_complete?/tracking_blockers read cleanly.
  ADDRESS_KEYS = %w[name phone address1 address2 city province zip country country_code company tax_id].freeze

  before_action :set_package, only: [ :show, :transition, :update_address, :update_item, :update_logistics, :update_note, :split, :merge, :apply_tracking, :retry_tracking, :label, :ship, :sync_shipment ]

  def index
    @state = STATES.include?(params[:state]) ? params[:state] : "pending_review"
    scope = scoped_packages.where(aasm_state: @state)
    scope = scope.where(application_status: params[:application_status]) if @state == "applying_tracking" && APPLICATION_STATUSES.include?(params[:application_status])

    # Filtering/ordering lives in the query object; the scope handed to it is
    # already company/store/state-authorized and the query object never widens
    # it. Pagination stays here.
    query = PackageListQuery.new(scope, country: params[:country],
                                        sort_column: params[:sort_column],
                                        sort_direction: params[:sort_direction])
    # Ordered by the LOCALIZED country name, which SQL can't do — parcel_country_name
    # resolves through i18n. Reached via the `helpers` proxy rather than including
    # ParcelsHelper, which would graft all its public methods onto the controller.
    @countries = query.countries.sort_by { |code| helpers.parcel_country_name(code).to_s }
    @country = query.country
    @sort_column = query.sort_column
    @sort_direction = query.sort_direction

    filtered = query.relation
    @page = [ params[:page].to_i, 1 ].max
    @total_count = filtered.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0
    # package_items -> product_variant -> product is what the SKU thumbnails
    # read; without it each SKU costs two more queries and a 50-row page turns
    # into hundreds.
    @packages = filtered.includes(:order, :shopify_store, :logistics_channel,
                                  package_items: { product_variant: :product })
                        .offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    # One query for the whole page's box numbering — see PackageSiblingIndex.
    # Must come after @packages is materialized; it reads their order_ids.
    @sibling_index = PackageSiblingIndex.new(@packages).call
  end

  def sync
    stores = selected_store ? [ selected_store ] : visible_shopify_stores
    stores.each { |s| SyncAllShopifyOrdersJob.perform_later(s.id) }
    redirect_back fallback_location: packages_path, notice: t("packages.sync_enqueued")
  end

  # Turbo Frame request (from the list's package_code link) renders just the
  # "_modal" partial into <turbo-frame id="package-modal">. A direct/non-frame
  # GET renders show.html.erb, which wraps that same partial in the frame tag
  # so the URL is also visitable on its own (e.g. a bookmark or shared link).
  def show
    render partial: "modal", locals: { package: @package } if turbo_frame_request?
  end

  # Drives one of Package's AASM bang events (submit_review!/back_to_review!/
  # hold!/unhold!/back_to_process!). REVIEW_EVENTS and PROCESS_EVENTS are
  # gated on separate Membership permissions (Task 1), so a member with only
  # one of package_review/package_process can perform their half but not the
  # other's — neither gate failure nor an AASM::InvalidTransition may ever
  # 500, both re-render the (unchanged) modal or redirect with an alert.
  def transition
    event = params[:event].to_s
    unless REVIEW_EVENTS.include?(event) || PROCESS_EVENTS.include?(event)
      return redirect_to(packages_path, alert: t("packages.invalid_action"))
    end
    unless authorized_for_event?(event)
      return redirect_to(packages_path, alert: t("companies.no_permission"))
    end

    fire_event!(event)
    respond_to do |format|
      format.turbo_stream { render :transition }
      format.html { redirect_to packages_path(state: @package.aasm_state), notice: t("packages.transitioned") }
    end
  rescue AASM::InvalidTransition
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace("package-modal", partial: "packages/modal", locals: { package: @package.reload }), status: :unprocessable_entity }
      format.html { redirect_to packages_path, alert: t("packages.invalid_transition") }
    end
  end

  # Manual address edit/save (gated on package_process, same as the hold/
  # unhold process actions). Setting address_overridden: true here is the
  # entire point of this action — PackageAutoBuilder#smart_update already
  # skips re-copying the Shopify shipping_address onto the snapshot when
  # this flag is set, so a human edit survives the order's next sync.
  # Editing does NOT enforce required-together validation: a partial save
  # is allowed to persist freely (completeness is only ever read via
  # Package#ready_for_tracking?/address_complete?, never enforced here).
  def update_address
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?

    snapshot = ADDRESS_KEYS.index_with { |k| params.dig(:address, k).to_s }
    @package.update!(shipping_address_snapshot: snapshot, address_overridden: true)
    respond_to do |format|
      format.turbo_stream { render :update_address }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.address_saved") }
    end
  end

  # Manual per-item customs edit (gated on package_process, same as
  # update_address). Setting customs_overridden: true is the entire point of
  # this action — PackageAutoBuilder#sync_items already skips re-copying the
  # product_variant's customs snapshot onto an item with this flag set, so a
  # human edit survives the order's next sync (see smart_update/sync_items).
  # Editing does NOT enforce required-together validation here — a partial
  # save is allowed to persist freely (completeness is only ever read via
  # Package#customs_complete?/PackageItem#customs_complete?, never enforced
  # on this write path). @item is looked up scoped to @package (which is
  # itself scoped to scoped_packages), so an item_id belonging to another
  # package can never be edited through this action.
  def update_item
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?

    @item = @package.package_items.find(params[:item_id])
    # `Package#package_items` declares inverse_of, so the `find` above reuses
    # the eager-loaded (set_package #includes) target object — the just-updated
    # item is the same instance the update_item stream's partials read, so no
    # reset/re-query is needed for a fresh completeness check.
    #
    # A negative declared_value/weight fails PackageItem's numericality
    # validation (a backstop behind the inputs' client-side min="0"). On that
    # failure the same update_item stream re-renders the row with the submitted
    # values + errors at 422 (row_edit_controller applies it either way) rather
    # than 500ing — mirroring the transition action's InvalidTransition rescue.
    saved = @item.update(customs_item_params.merge(customs_overridden: true))
    respond_to do |format|
      format.turbo_stream { render :update_item, status: saved ? :ok : :unprocessable_entity }
      format.html do
        if saved
          redirect_to package_path(id: @package.id), notice: t("packages.item_saved")
        else
          redirect_to package_path(id: @package.id), alert: t("packages.item_invalid")
        end
      end
    end
  end

  # Assign/unassign the package's logistics channel (gated on package_process,
  # same as update_address/update_item). Only channels belonging to the
  # current company's raydo logistics account are assignable — company_
  # logistics_channels enforces that scoping, so passing another company's
  # channel id is rejected with an alert rather than silently cross-wiring
  # the package to a foreign channel (set_package already keeps the PACKAGE
  # itself company-scoped; this guard is specifically for the channel id in
  # params, which is a separate record with its own company ownership).
  def update_logistics
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?

    channel_id = params[:logistics_channel_id].presence
    channel = channel_id && company_logistics_channels.find_by(id: channel_id)
    if channel_id && channel.nil?
      return redirect_to(package_path(id: @package.id), alert: t("packages.invalid_channel"))
    end

    @package.update!(logistics_channel_id: channel&.id)
    respond_to do |format|
      format.turbo_stream { render :update_logistics }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.logistics_saved") }
    end
  end

  # Manual note edit (gated on package_process, same as the other manual
  # edit actions in this controller).
  def update_note
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?

    @package.update!(note: params[:note].to_s)
    respond_to do |format|
      format.turbo_stream { render :update_note }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.note_saved") }
    end
  end

  # Folds this pending_process package into new sibling boxes (see
  # PackageSplitter). Gated on package_process, same as the other manual edits.
  # Invalid allocations re-render the modal at 422 (never 500); a non-
  # pending_process source is rejected before the service runs.
  def split
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    unless @package.pending_process?
      return redirect_to(package_path(id: @package.id), alert: t("packages.split_invalid_state"))
    end
    # Package#split? is what _split_dialog uses to hide the button once this
    # package is already folded into boxes — that view-only guard is not
    # sufficient by itself (a stale form, still open from before the first
    # split landed, can still POST here). Enforce the same invariant
    # server-side so a second submit can't mint a third box.
    if @package.split?
      return redirect_to(package_path(id: @package.id), alert: t("packages.split_invalid_state"))
    end

    # Explicit, controller-owned signal for split.turbo_stream.erb: the
    # standalone /packages/:id page (show.html.erb) has no list row for
    # `turbo_stream.replace dom_id(@package)` to hit and its modal wrapper
    # doesn't listen for modal:dismiss, so a dismiss+replace stream there
    # would silently do nothing. _split_dialog only renders the
    # `context=standalone` hidden field when show.html.erb rendered it (see
    # that view), so this is never a referer guess.
    @standalone = params[:context] == "standalone"

    result = PackageSplitter.new(@package, split_allocations).call
    if result.success?
      respond_to do |format|
        format.turbo_stream { render :split }
        format.html { redirect_to(@standalone ? packages_path(state: @package.aasm_state) : package_path(id: @package.id), notice: t("packages.split_done")) }
      end
    else
      @split_errors = result.errors
      respond_to do |format|
        format.turbo_stream { render :split, status: :unprocessable_entity }
        format.html { redirect_to package_path(id: @package.id), alert: t("packages.split_invalid") }
      end
    end
  end

  # Collapses this order's split boxes back into the lowest-numbered survivor
  # (see PackageMerger). Gated on package_process. The modal reloads to show the
  # survivor; count returns to 1 so auto-sync resumes on the next order sync.
  def merge
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    unless @package.pending_process?
      return redirect_to(package_path(id: @package.id), alert: t("packages.split_invalid_state"))
    end

    # Explicit, controller-owned signal for merge.turbo_stream.erb — mirrors
    # #split's @standalone: the standalone /packages/:id page (show.html.erb)
    # has no list row for `turbo_stream.replace dom_id(@survivor)`/`.remove`
    # to hit and its modal wrapper doesn't listen for modal:dismiss, so a
    # dismiss+replace+remove stream there would silently do nothing.
    # _siblings_strip only sends context=standalone when show.html.erb
    # rendered it (see that view), so this is never a referer guess.
    @standalone = params[:context] == "standalone"

    # PackageMerger destroys the absorbed boxes, so the rows to remove from the
    # list have to be captured BEFORE the call — afterwards there is nothing
    # left to ask. These are in-memory (now destroyed) records, which is all
    # dom_id needs. Note the merger only folds pending_process siblings, so a
    # box of this order sitting in another state is deliberately not in here.
    # #pending_siblings is memoized on the merger instance, so #call's own
    # internal read of it below reuses THIS query result rather than issuing
    # a second one — the removed set is guaranteed to match what was destroyed.
    merger = PackageMerger.new(@package)
    siblings = merger.pending_siblings
    @survivor = merger.call
    @absorbed = siblings.reject { |box| box.id == @survivor.id }
    respond_to do |format|
      format.turbo_stream { render :merge }
      format.html { redirect_to package_path(id: @survivor.id), notice: t("packages.merge_done") }
    end
  end

  # Apply for a Raydo tracking number (gated on package_process). Blocks a
  # not-ready package (422 + blockers, no transition); a non-pending_process
  # package is rejected before the transition. On success: move to
  # applying_tracking (application_status=pending) and enqueue ApplyTrackingJob.
  def apply_tracking
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    unless @package.pending_process?
      return redirect_to(package_path(id: @package.id), alert: t("packages.apply.invalid_state"))
    end
    unless @package.ready_for_tracking?
      respond_to do |format|
        format.turbo_stream { render :apply_tracking, status: :unprocessable_entity }
        format.html { redirect_to package_path(id: @package.id), alert: t("packages.apply.not_ready") }
      end
      return
    end

    start_application!(@package)
    respond_to do |format|
      format.turbo_stream { render :apply_tracking }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.apply.enqueued") }
    end
  end

  # Retry a failed application (still in applying_tracking). Resets to pending
  # and re-enqueues; the applier is idempotent (polls if an order already
  # exists, else re-creates).
  def retry_tracking
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    unless @package.applying_tracking? && @package.application_status == "failed"
      return redirect_to(package_path(id: @package.id), alert: t("packages.apply.invalid_state"))
    end

    @package.update!(application_status: "pending", application_message: nil)
    ApplyTrackingJob.perform_later(@package.id)
    respond_to do |format|
      format.turbo_stream { render :apply_tracking }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.apply.enqueued") }
    end
  end

  # Bulk apply from the pending_process list. Ready packages are applied +
  # enqueued; not-ready ones are skipped and reported. Per-package isolation
  # (mirrors PollTrackingNumbersJob#perform) so a package whose state raced
  # between the scope query above and the apply_tracking! bang below (raising
  # AASM::InvalidTransition) — or one that fails its update! (ActiveRecord::
  # ActiveRecordError) — is counted as skipped rather than aborting the rest
  # of the batch.
  def apply_tracking_bulk
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?

    ids = Array(params[:package_ids]).map(&:to_s)
    candidates = scoped_packages.where(id: ids, aasm_state: "pending_process")
    applied = 0
    skipped = 0
    candidates.find_each do |package|
      if package.ready_for_tracking?
        begin
          start_application!(package)
          applied += 1
        rescue AASM::InvalidTransition, ActiveRecord::ActiveRecordError => e
          Rails.logger.warn("[ApplyBulk] Package##{package.id}: #{e.class}: #{e.message}")
          skipped += 1
        end
      else
        skipped += 1
      end
    end
    redirect_to packages_path(list_filter_params.merge(state: "pending_process")), notice: t("packages.apply.bulk_result", applied: applied, skipped: skipped)
  end

  # Stream the Raydo label PDF for one pending_label package (gated on
  # package_shipping). No state change — labels are re-printable. On any failure
  # we can't embed an error in a PDF response, so redirect back with an alert.
  def label
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_shipping?

    result = PackageLabelPrinter.new([ @package ]).call
    if result.success?
      send_data result.pdf, type: "application/pdf", disposition: "inline", filename: result.filename
    else
      redirect_to packages_path(list_filter_params.merge(state: "pending_label")), alert: label_error_message(result.error)
    end
  end

  # Bulk label print: one combined PDF for the selected pending_label packages
  # (must share a label_print_type). Gated on package_shipping.
  def labels
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_shipping?

    ids = Array(params[:package_ids]).map(&:to_s)
    packages = scoped_packages.where(id: ids, aasm_state: "pending_label").to_a
    result = PackageLabelPrinter.new(packages).call
    if result.success?
      send_data result.pdf, type: "application/pdf", disposition: "inline", filename: result.filename
    else
      redirect_to packages_path(list_filter_params.merge(state: "pending_label")), alert: label_error_message(result.error)
    end
  end

  # Marks one pending_label package as shipped (gated on package_shipping).
  # The actual transition + tracking-number check happen atomically inside
  # ship_package (Codex: row lock guards a double-click race). :ok re-renders
  # the modal (turbo_stream) or redirects with a notice; any other outcome
  # redirects with an alert — never a 500.
  def ship
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_shipping?

    result = ship_package(@package)
    if result == :ok
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace("package-modal", partial: "packages/modal", locals: { package: @package.reload }) }
        format.html { redirect_to package_path(id: @package.id), notice: t("packages.ship.done") }
      end
    else
      redirect_to package_path(id: @package.id), alert: t("packages.ship.errors.#{result}", default: t("packages.ship.errors.failed"))
    end
  end

  # Bulk ship from the pending_label list (gated on package_shipping). Each
  # package goes through the same atomic ship_package helper; a raised error
  # on one package is logged and skipped rather than aborting the batch
  # (mirrors apply_tracking_bulk's per-package isolation).
  def ship_bulk
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_shipping?

    ids = Array(params[:package_ids]).map(&:to_s)
    shipped = 0
    scoped_packages.where(id: ids, aasm_state: "pending_label").find_each do |package|
      shipped += 1 if ship_package(package) == :ok
    rescue => e
      Rails.logger.warn("[ShipBulk] Package##{package.id}: #{e.class}: #{e.message}")
    end
    redirect_to packages_path(list_filter_params.merge(state: "pending_label")), notice: t("packages.ship.bulk_result", shipped: shipped)
  end

  # Bulk review from the pending_review list (gated on package_review, the same
  # permission that guards REVIEW_EVENTS in #transition). Per-package isolation
  # mirrors apply_tracking_bulk/ship_bulk: a package whose state raced between
  # the scope query and submit_review! (AASM::InvalidTransition) is counted as
  # skipped rather than aborting the rest of the batch.
  def submit_review_bulk
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_review?

    ids = Array(params[:package_ids]).map(&:to_s)
    reviewed = 0
    skipped = 0
    scoped_packages.where(id: ids, aasm_state: "pending_review").find_each do |package|
      package.submit_review!
      reviewed += 1
    rescue AASM::InvalidTransition, ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[ReviewBulk] Package##{package.id}: #{e.class}: #{e.message}")
      skipped += 1
    end
    redirect_to packages_path(list_filter_params.merge(state: "pending_review")),
                notice: t("packages.review.bulk_result", reviewed: reviewed, skipped: skipped)
  end

  # Re-enqueue the Shopify fulfillment sync for a shipped package whose
  # previous sync failed (or was never enqueued because the store toggle was
  # off at ship time). Gated on package_shipping AND the store's current
  # shipping_sync_enabled toggle — this action never proceeds if the store
  # doesn't want automatic fulfillment sync.
  def sync_shipment
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_shipping?
    unless @package.shipped? && %w[failed none].include?(@package.ship_sync_status)
      return redirect_to(package_path(id: @package.id), alert: t("packages.ship.errors.sync_invalid"))
    end
    unless @package.shopify_store.shipping_sync_enabled?
      return redirect_to(package_path(id: @package.id), alert: t("packages.ship.errors.sync_disabled"))
    end

    @package.update!(ship_sync_status: "pending", ship_sync_message: nil)
    PackageShipSyncJob.perform_later(@package.id)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace("package-modal", partial: "packages/modal", locals: { package: @package.reload }) }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.ship.sync_enqueued") }
    end
  end

  private

  # The list filters, carried back through a bulk action's redirect. Without
  # this, one click on a bulk button silently resets the user's country/sort
  # selection. Values are re-validated by PackageListQuery on the way back in,
  # so this only has to move them.
  def list_filter_params
    params.permit(:country, :sort_column, :sort_direction).to_h.compact_blank.symbolize_keys
  end

  # Atomically transition to shipped + set status + decide enqueue (Codex: row
  # lock to avoid double-click races). Returns :ok, :not_pending, :no_tracking.
  # The job is enqueued OUTSIDE the lock (after the transaction commits) so a
  # job worker can never race ahead of the row lock's release.
  def ship_package(package)
    enqueue = false
    outcome = package.with_lock do
      next :not_pending unless package.pending_label?
      next :no_tracking if package.tracking_number.blank?

      package.ship!
      attrs = { shipped_at: Time.current }
      if package.shopify_store.shipping_sync_enabled?
        attrs.merge!(ship_sync_status: "pending", ship_sync_message: nil)
        enqueue = true
      end
      package.update!(attrs)
      :ok
    end
    PackageShipSyncJob.perform_later(package.id) if enqueue && outcome == :ok
    outcome
  end

  # Map a PackageLabelPrinter failure (symbol for a validation reason, or a raw
  # Raydo error string) to a user-facing flash. Unknown/raw errors fall back to
  # the generic "failed" message (never surfaces a raw carrier string verbatim).
  def label_error_message(error)
    key = error.is_a?(Symbol) ? error : :failed
    t("packages.label.errors.#{key}", default: t("packages.label.errors.failed"))
  end

  # Move a ready package into applying_tracking (pending) and enqueue the job.
  # applied_at is left nil here — the applier stamps it when Raydo actually
  # creates the order (the correct anchor for the poll give-up).
  def start_application!(package)
    package.apply_tracking!
    package.update!(application_status: "pending", application_message: nil)
    ApplyTrackingJob.perform_later(package.id)
  end

  # Explicit dispatch (rather than @package.public_send("#{event}!")) so a
  # user-controlled string never reaches a dynamic method invocation — event
  # is already whitelisted against REVIEW_EVENTS/PROCESS_EVENTS by the caller,
  # but this keeps Brakeman's static "Dangerous Send" check clean too.
  def fire_event!(event)
    case event
    when "submit_review"   then @package.submit_review!
    when "back_to_review"  then @package.back_to_review!
    when "hold"            then @package.hold!
    when "unhold"          then @package.unhold!
    when "back_to_process" then @package.back_to_process!
    end
  end

  def authorized_for_event?(event)
    m = current_membership
    return false unless m

    REVIEW_EVENTS.include?(event) ? m.package_review? : m.package_process?
  end

  def customs_item_params
    params.require(:package_item).permit(
      :customs_name_zh, :customs_name_en, :declared_value_usd, :hs_code, :import_hs_code, :customs_weight_grams
    )
  end

  # Split allocations arrive as a dynamic hash keyed by order_line_item UUIDs
  # ({ li_id => [box1_units, box2_units, ...] }), so a fixed strong-params
  # permit list can't name the keys. to_unsafe_h is safe here: every key is
  # validated against the source package's own items inside PackageSplitter
  # (unknown ids → :unknown_item, 422), and values are coerced to integers, so
  # nothing user-controlled reaches a query or mass-assignment unchecked.
  def split_allocations
    raw = params[:allocations]
    return {} unless raw.respond_to?(:to_unsafe_h) || raw.is_a?(Hash)

    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    raw.to_h.transform_values { |arr| Array(arr).map { |v| v.to_s.to_i } }
  end

  # scoped_packages.find raises ActiveRecord::RecordNotFound for a package
  # belonging to another company/store — no rescue_from is defined anywhere
  # in this app's controller chain, so it propagates to Rails' default
  # exception handling (404 in production; the same 404 rendering in test,
  # since config.action_dispatch.show_exceptions = :rescuable there).
  def set_package
    @package = scoped_packages.includes(
      :package_items, :logistics_channel, :shopify_store,
      order: [ :customer, :order_line_items ]
    ).find(params[:id])
  end

  # Cross-company safety: only this company's raydo channels are assignable
  # to a package via update_logistics — used both to populate the edit
  # form's <select> and to validate a submitted logistics_channel_id.
  def company_logistics_channels
    account = current_company.logistics_accounts.find_by(provider: "raydo")
    account ? account.logistics_channels.order(:name) : LogisticsChannel.none
  end
  helper_method :company_logistics_channels

  # Overrides AdminController#authorize_page! (a before_action referenced by
  # symbol, so this subclass definition is what actually runs) to gate on ANY
  # packing permission instead of the single "packages" controller-name key —
  # package_review/package_process/package_shipping (or owner) all grant read
  # access to this list, per Task 5's Membership#any_packing_permission?.
  def authorize_page!
    return if current_membership&.any_packing_permission?

    redirect_to authenticated_root_path, alert: t("companies.no_permission")
  end

  # The packing list's own store filter. Unlike current_shopify_store this reads
  # ONLY the URL — nothing is persisted, so choosing a store here cannot follow
  # the user to another page (see AdminController#persist_store_selection, which
  # no longer fires for this controller).
  #
  # nil means "every visible store". An unknown id, or one belonging to another
  # company, resolves to nil rather than 404ing: visible_shopify_stores is the
  # isolation boundary, so a foreign id simply finds nothing.
  def selected_store
    return @selected_store if defined?(@selected_store)

    @selected_store = visible_shopify_stores.find_by(id: params[:store])
  end
  helper_method :selected_store

  # Scoped to the store chosen in the list's own store filter (params[:store])
  # when one is chosen, else to every store the membership can see. Either way
  # the ids come from visible_shopify_stores, so cross-company/cross-group
  # isolation holds.
  def scoped_packages
    store_ids = selected_store ? [ selected_store.id ] : visible_shopify_stores.select(:id)
    Package.where(shopify_store_id: store_ids)
  end
end
