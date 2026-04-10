class ProfilesController < AdminController
  skip_before_action :authorize_page!

  def edit
  end

  def update
    if needs_password_change?
      unless current_user.valid_password?(params.dig(:user, :current_password).to_s)
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
    params.require(:user).permit(:first_name, :last_name, :locale)
  end

  def profile_params_with_password
    params.require(:user).permit(:first_name, :last_name, :locale, :password, :password_confirmation)
  end

  def needs_password_change?
    params.dig(:user, :password).present?
  end
end
