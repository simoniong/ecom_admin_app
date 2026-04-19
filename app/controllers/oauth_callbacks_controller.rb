class OauthCallbacksController < AdminController
  def google_oauth2
    auth = request.env["omniauth.auth"]

    unless auth
      redirect_to email_accounts_path, alert: t("email_accounts.oauth_failure")
      return
    end

    email_account = current_company.email_accounts.find_or_initialize_by(google_uid: auth.uid)
    email_account.user = current_user
    if email_account.new_record? && (pending_group_id = session.delete(:pending_binding_group_id)).present?
      email_account.group_id = pending_group_id
    end
    email_account.assign_attributes(
      email: auth.info.email,
      access_token: auth.credentials.token,
      refresh_token: auth.credentials.refresh_token || email_account.refresh_token,
      token_expires_at: auth.credentials.expires_at ? Time.zone.at(auth.credentials.expires_at) : nil,
      scopes: auth.credentials.try(:scope) || ""
    )

    if email_account.save
      redirect_to email_accounts_path, notice: t("email_accounts.bind_success")
    else
      redirect_to email_accounts_path, alert: t("email_accounts.bind_failure")
    end
  end

  def failure
    redirect_to email_accounts_path, alert: t("email_accounts.oauth_failure")
  end
end
