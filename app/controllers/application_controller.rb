class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :set_locale

  private

  def set_locale
    locale = params[:locale] || session[:locale] || current_user&.locale || I18n.default_locale
    I18n.locale = locale
    session[:locale] = I18n.locale

    # Persist to user when explicitly switching via URL param
    if params[:locale].present? && current_user && current_user.locale != I18n.locale.to_s
      current_user.update_column(:locale, I18n.locale.to_s)
    end
  end

  def default_url_options
    { locale: I18n.locale == I18n.default_locale ? nil : I18n.locale }
  end
end
