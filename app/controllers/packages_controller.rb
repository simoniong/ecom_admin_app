class PackagesController < AdminController
  PER_PAGE = 50
  STATES = %w[pending_review pending_process applying_tracking pending_label shipped refunded held].freeze
  APPLICATION_STATUSES = %w[pending success failed].freeze

  def index
    @state = STATES.include?(params[:state]) ? params[:state] : "pending_review"
    scope = scoped_packages.where(aasm_state: @state)
    scope = scope.where(application_status: params[:application_status]) if @state == "applying_tracking" && params[:application_status].present?
    @counts = scoped_packages.group(:aasm_state).count
    @page = [ params[:page].to_i, 1 ].max
    @total_count = scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0
    @packages = scope.includes(:order, :package_items, :shopify_store)
                     .order(created_at: :desc)
                     .offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  private

  # Overrides AdminController#authorize_page! (a before_action referenced by
  # symbol, so this subclass definition is what actually runs) to gate on ANY
  # packing permission instead of the single "packages" controller-name key —
  # package_review/package_process/package_shipping (or owner) all grant read
  # access to this list, per Task 5's Membership#any_packing_permission?.
  def authorize_page!
    return if current_membership&.any_packing_permission?

    redirect_to authenticated_root_path, alert: t("companies.no_permission")
  end

  def scoped_packages
    Package.where(shopify_store_id: visible_shopify_stores.select(:id))
  end
end
