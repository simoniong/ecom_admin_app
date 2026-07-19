class AdminController < ApplicationController
  before_action :authenticate_user!
  before_action :set_current_company
  before_action :authorize_page!
  before_action :persist_store_selection
  layout "admin"

  PERMISSION_KEY_MAP = {
    "shopify_oauth" => "shopify_stores",
    "oauth_callbacks" => "email_accounts",
    "meta_oauth" => "ad_accounts",
    "campaign_display_templates" => "ad_campaigns",
    "shipping_reminder_settings" => "shipping_reminder_rules",
    "email_workflows" => "shopify_stores",
    "email_workflow_steps" => "shopify_stores",
    "products" => "products",
    "product_variants" => "products",
    "product_customs" => "products",
    "shipping_rate_card_versions" => "shopify_stores",
    "shipping_rate_card_rates"    => "shopify_stores",
    "shipping_zone_postal_rules" => "shopify_stores",
    "shipping_remote_area_versions" => "shopify_stores",
    "shipping_remote_area_rules"    => "shopify_stores",
    "logistics_channels" => "logistics_channels",
    "logistics_accounts" => "logistics_channels"
  }.freeze

  STORE_SWITCHER_CONTROLLERS = %w[dashboard orders shipments tickets ad_campaigns].freeze
  STORE_ALL_ALLOWED_CONTROLLERS = %w[dashboard shipments].freeze

  private

  def set_current_company
    @current_company = if session[:company_id].present?
      current_user.companies.find_by(id: session[:company_id])
    end
    @current_company ||= current_user.companies.first

    if @current_company.nil?
      redirect_to root_path, alert: t("companies.no_company")
      return
    end

    session[:company_id] = @current_company.id
  end

  def current_company
    @current_company
  end
  helper_method :current_company

  def current_membership
    @current_membership ||= current_user.membership_for(current_company)
  end
  helper_method :current_membership

  def current_group
    return @current_group if defined?(@current_group)

    @current_group = current_membership&.group
  end
  helper_method :current_group

  def company_has_groups?
    return @company_has_groups if defined?(@company_has_groups)

    @company_has_groups = current_company.groups.exists?
  end
  helper_method :company_has_groups?

  def visible_shopify_stores
    visible_resource(current_company.shopify_stores, :shopify_stores)
  end
  helper_method :visible_shopify_stores

  def visible_ad_accounts
    visible_resource(current_company.ad_accounts, :ad_accounts)
  end
  helper_method :visible_ad_accounts

  def visible_email_accounts
    visible_resource(current_company.email_accounts, :email_accounts)
  end
  helper_method :visible_email_accounts

  def visible_tickets
    accounts = visible_email_accounts
    # Filter by the selected store, but always keep accounts not linked to any
    # store (shopify_store_id IS NULL) — those tickets aren't store-specific and
    # must stay visible in every store view. Group isolation is already enforced
    # by visible_email_accounts.
    if current_shopify_store
      accounts = accounts.where(shopify_store_id: [ current_shopify_store.id, nil ])
    end
    Ticket.where(email_account_id: accounts.select(:id))
  end
  helper_method :visible_tickets

  def resolve_binding_group(param_value)
    return nil unless company_has_groups?
    return current_group unless current_membership&.owner?

    current_company.groups.find_by(id: param_value)
  end

  def selected_view_group
    return @selected_view_group if defined?(@selected_view_group)

    @selected_view_group = compute_selected_view_group
  end
  helper_method :selected_view_group

  def authorize_page!
    unless current_membership&.has_permission?(permission_key)
      redirect_to authenticated_root_path, alert: t("companies.no_permission")
    end
  end

  def permission_key
    PERMISSION_KEY_MAP.fetch(controller_name, controller_name)
  end

  def require_tracking_enabled!
    return if current_company&.tracking_enabled?

    key = current_membership&.owner? ? :tracking_disabled_owner : :tracking_disabled_member
    redirect_to authenticated_root_path, alert: t("companies.#{key}")
  end

  def current_shopify_store
    return @current_shopify_store if defined?(@current_shopify_store)

    @current_shopify_store = resolve_current_store
  end
  helper_method :current_shopify_store

  def store_switcher_visible?
    STORE_SWITCHER_CONTROLLERS.include?(controller_name)
  end
  helper_method :store_switcher_visible?

  def store_all_allowed?
    STORE_ALL_ALLOWED_CONTROLLERS.include?(controller_name)
  end
  helper_method :store_all_allowed?

  def store_timezone
    @store_timezone ||= current_shopify_store&.active_timezone || ActiveSupport::TimeZone["UTC"]
  end
  helper_method :store_timezone

  def persist_store_selection
    return unless store_switcher_visible?
    return if params[:store_id] == "all" && !store_all_allowed?

    session[:store_id] = params[:store_id] if params[:store_id].present?
  end

  def resolve_current_store
    stores = visible_shopify_stores

    unless store_switcher_visible?
      return stores.find_by(id: params[:store_id]) if params[:store_id].present?

      return stores.first if stores.count == 1

      return nil
    end

    raw = params[:store_id].presence || session[:store_id].presence

    if raw == "all"
      return nil if store_all_allowed?

      return stores.first
    end

    if raw.present?
      found = stores.find_by(id: raw)
      return found if found
    end

    store_all_allowed? ? nil : stores.first
  end

  def visible_resource(base, association)
    return base if current_membership&.owner?
    return base unless company_has_groups?
    return base.none if current_group.nil?

    current_group.public_send(association)
  end

  def compute_selected_view_group
    return current_group unless current_membership&.owner?

    param_value = params[:group_id].to_s
    if param_value.present?
      if param_value == "all"
        session[:view_group_id] = nil
        return nil
      end

      group = current_company.groups.find_by(id: param_value)
      session[:view_group_id] = group&.id
      return group
    end

    return nil if session[:view_group_id].blank?

    group = current_company.groups.find_by(id: session[:view_group_id])
    session[:view_group_id] = nil if group.nil?
    group
  end
end
