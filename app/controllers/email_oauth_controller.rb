class EmailOauthController < AdminController
  skip_before_action :authorize_page!

  def start
    return redirect_to(authenticated_root_path, alert: t("companies.no_permission")) unless current_membership&.has_permission?("email_accounts")

    if company_has_groups?
      group = resolve_binding_group(params[:group_id])
      if group.nil?
        redirect_to email_accounts_path, alert: t("email_accounts.group_required")
        return
      end
      session[:pending_binding_group_id] = group.id
    else
      session.delete(:pending_binding_group_id)
    end

    redirect_to "/auth/google_oauth2", status: :temporary_redirect
  end
end
