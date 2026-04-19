class MetaOauthController < AdminController
  def auth
    if company_has_groups?
      group = resolve_binding_group(params[:group_id])
      if group.nil?
        redirect_to ad_accounts_path, alert: t("ad_accounts.group_required")
        return
      end
      session[:pending_binding_group_id] = group.id
    else
      session.delete(:pending_binding_group_id)
    end

    state = SecureRandom.hex(24)
    session[:meta_oauth_state] = state

    oauth = Koala::Facebook::OAuth.new(meta_app_id, meta_app_secret, meta_callback_url)
    redirect_to oauth.url_for_oauth_code(
      permissions: "ads_management,ads_read",
      state: state
    ), allow_other_host: true
  end

  def callback
    unless params[:state] == session.delete(:meta_oauth_state)
      redirect_to ad_accounts_path, alert: t("ad_accounts.oauth_failure")
      return
    end

    if params[:error].present? || params[:code].blank?
      redirect_to ad_accounts_path, alert: t("ad_accounts.oauth_failure")
      return
    end

    oauth = Koala::Facebook::OAuth.new(meta_app_id, meta_app_secret, meta_callback_url)
    short_token = oauth.get_access_token(params[:code])
    long_token_info = oauth.exchange_access_token_info(short_token)
    long_token = long_token_info["access_token"]
    expires_in = long_token_info["expires_in"]&.to_i

    graph = Koala::Facebook::API.new(long_token)
    ad_accounts_data = graph.get_connections("me", "adaccounts", fields: "account_id,name,account_status,timezone_name")

    session[:meta_long_token] = long_token
    session[:meta_token_expires_at] = (expires_in ? (Time.current + expires_in.seconds).iso8601 : nil)

    @ad_accounts = ad_accounts_data.select { |a| a["account_status"] == 1 }
    render :select_accounts
  rescue Koala::Facebook::OAuthTokenRequestError, Koala::Facebook::ClientError, Koala::KoalaError => e
    Rails.logger.warn("Meta OAuth callback error: #{e.class}: #{e.message}")
    redirect_to ad_accounts_path, alert: t("ad_accounts.oauth_failure")
  end

  def select_accounts
    token = session.delete(:meta_long_token)
    expires_at_str = session.delete(:meta_token_expires_at)

    if token.blank?
      redirect_to ad_accounts_path, alert: t("ad_accounts.oauth_failure")
      return
    end

    expires_at = expires_at_str ? Time.zone.parse(expires_at_str) : nil
    account_ids = params[:account_ids] || []

    if account_ids.empty?
      redirect_to ad_accounts_path, alert: t("ad_accounts.no_accounts_selected")
      return
    end

    pending_group_id = session.delete(:pending_binding_group_id)
    account_ids.each do |acct_id|
      name = params.dig(:account_names, acct_id)
      timezone = params.dig(:account_timezones, acct_id)
      ad_account = current_company.ad_accounts.find_or_initialize_by(platform: "meta", account_id: "act_#{acct_id}")
      ad_account.user = current_user
      ad_account.group_id = pending_group_id if ad_account.new_record? && pending_group_id.present?
      validated_tz = ActiveSupport::TimeZone[timezone.to_s] ? timezone : "UTC"
      ad_account.assign_attributes(account_name: name, access_token: token, token_expires_at: expires_at, timezone: validated_tz)
      ad_account.save!
    end

    redirect_to ad_accounts_path, notice: t("ad_accounts.bind_success")
  end

  private

  def meta_app_id
    ENV["META_APP_ID"] || Rails.application.credentials.dig(:meta, :app_id)
  end

  def meta_app_secret
    ENV["META_APP_SECRET"] || Rails.application.credentials.dig(:meta, :app_secret)
  end

  def meta_callback_url
    "#{request.base_url}/meta/callback"
  end
end
