class AdminController < ApplicationController
  before_action :authenticate_user!
  layout "admin"

  private

  def current_shopify_store
    @current_shopify_store ||= begin
      stores = current_user.shopify_stores
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
