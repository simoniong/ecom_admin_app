class AdminController < ApplicationController
  before_action :authenticate_user!
  before_action :set_current_company
  before_action :authorize_page!
  layout "admin"

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

  PERMISSION_KEY_MAP = {
    "shopify_oauth" => "shopify_stores",
    "oauth_callbacks" => "email_accounts",
    "meta_oauth" => "ad_accounts",
    "campaign_display_templates" => "ad_campaigns",
    "shipping_reminder_settings" => "shipping_reminder_rules",
    "email_workflows" => "shopify_stores",
    "email_workflow_steps" => "shopify_stores"
  }.freeze

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
    @current_shopify_store ||= begin
      stores = current_company.shopify_stores
      if params[:store_id].present?
        stores.find_by(id: params[:store_id])
      else
        stores.first if stores.count == 1
      end
    end
  end
  helper_method :current_shopify_store

  def store_timezone
    @store_timezone ||= current_shopify_store&.active_timezone || ActiveSupport::TimeZone["UTC"]
  end
  helper_method :store_timezone
end
