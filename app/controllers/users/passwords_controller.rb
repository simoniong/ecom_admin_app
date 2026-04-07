class Users::PasswordsController < Devise::PasswordsController
  layout "auth"
  before_action :set_locale

  private

  def set_locale
    I18n.locale = params[:locale] || session[:locale] || I18n.default_locale
    session[:locale] = I18n.locale
  end
end
