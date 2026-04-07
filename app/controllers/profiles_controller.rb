class ProfilesController < ApplicationController
  before_action :authenticate_user!
  layout "admin"

  def edit
  end

  def update
    if needs_password_change?
      unless current_user.valid_password?(params[:user][:current_password])
        current_user.errors.add(:current_password, :invalid)
        render :edit, status: :unprocessable_entity
        return
      end

      if current_user.update(profile_params_with_password)
        bypass_sign_in(current_user)
        redirect_to edit_profile_path, notice: t("profile.updated")
      else
        render :edit, status: :unprocessable_entity
      end
    else
      if current_user.update(profile_params)
        redirect_to edit_profile_path, notice: t("profile.updated")
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  private

  def profile_params
    params.require(:user).permit(:first_name, :last_name)
  end

  def profile_params_with_password
    params.require(:user).permit(:first_name, :last_name, :password, :password_confirmation)
  end

  def needs_password_change?
    params[:user][:password].present?
  end
end
