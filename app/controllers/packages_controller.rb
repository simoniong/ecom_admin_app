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

  before_action :set_package, only: [ :show, :transition, :update_address, :update_item ]

  def index
    @state = STATES.include?(params[:state]) ? params[:state] : "pending_review"
    scope = scoped_packages.where(aasm_state: @state)
    scope = scope.where(application_status: params[:application_status]) if @state == "applying_tracking" && APPLICATION_STATUSES.include?(params[:application_status])
    @page = [ params[:page].to_i, 1 ].max
    @total_count = scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0
    @packages = scope.includes(:order, :package_items, :shopify_store, :logistics_channel)
                     .order(created_at: :desc)
                     .offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def sync
    stores = current_shopify_store ? [ current_shopify_store ] : visible_shopify_stores
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
    @item.update!(customs_item_params.merge(customs_overridden: true))
    # set_package's #includes eager-loads :package_items, but the collection
    # association here has no explicit inverse_of, so the `find` above always
    # hits the DB for a fresh object rather than reusing the cached target —
    # @item is therefore a DIFFERENT in-memory object than the (stale) one
    # still sitting in @package.package_items' loaded array. Reset it so the
    # customs_status_badge partial's Package#customs_complete? (rendered
    # below) sees the just-updated item instead of stale pre-update data.
    @package.package_items.reset
    respond_to do |format|
      format.turbo_stream { render :update_item }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.item_saved") }
    end
  end

  private

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

  # Overrides AdminController#authorize_page! (a before_action referenced by
  # symbol, so this subclass definition is what actually runs) to gate on ANY
  # packing permission instead of the single "packages" controller-name key —
  # package_review/package_process/package_shipping (or owner) all grant read
  # access to this list, per Task 5's Membership#any_packing_permission?.
  def authorize_page!
    return if current_membership&.any_packing_permission?

    redirect_to authenticated_root_path, alert: t("companies.no_permission")
  end

  # Scoped to the currently-selected store (via the store switcher) when one
  # is chosen, else to every store the membership can see — mirrors
  # OrdersController#index so the packages list respects the switcher the
  # same way orders do. current_shopify_store is still derived from
  # visible_shopify_stores, so cross-company/cross-group isolation holds
  # either way.
  def scoped_packages
    store_ids = current_shopify_store ? [ current_shopify_store.id ] : visible_shopify_stores.select(:id)
    Package.where(shopify_store_id: store_ids)
  end
end
