class PackagesController < AdminController
  PER_PAGE = 50
  STATES = %w[pending_review pending_process applying_tracking pending_label shipped refunded held].freeze
  APPLICATION_STATUSES = %w[pending succeeded failed].freeze

  before_action :set_package, only: :show

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

  private

  # scoped_packages.find raises ActiveRecord::RecordNotFound for a package
  # belonging to another company/store — no rescue_from is defined anywhere
  # in this app's controller chain, so it propagates to Rails' default
  # exception handling (404 in production; the same 404 rendering in test,
  # since config.action_dispatch.show_exceptions = :rescuable there).
  def set_package
    @package = scoped_packages.includes(:order, :package_items, :logistics_channel, :shopify_store).find(params[:id])
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
