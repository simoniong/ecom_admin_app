class AdminController < ApplicationController
  before_action :authenticate_user!
  layout "admin"

  private

  def store_timezone
    @store_timezone ||= begin
      tz = current_user.shopify_stores.pick(:timezone)
      tz.present? ? (ActiveSupport::TimeZone[tz] || ActiveSupport::TimeZone["UTC"]) : ActiveSupport::TimeZone["UTC"]
    end
  end
  helper_method :store_timezone
end
