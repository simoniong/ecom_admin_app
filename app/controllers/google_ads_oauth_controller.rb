class GoogleAdsOauthController < AdminController
  # Covers the account's history on connect, so the dashboard's longer ranges
  # (quarters, "Maximum") include Google spend from the start. One GAQL
  # search returns every day in a single request.
  BACKFILL_DAYS = 730

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
    session[:google_ads_oauth_state] = state

    redirect_to GoogleAdsApi.authorization_url(redirect_uri: google_ads_callback_url, state: state),
                allow_other_host: true
  end

  def callback
    unless params[:state].present? && params[:state] == session.delete(:google_ads_oauth_state)
      redirect_to ad_accounts_path, alert: t("ad_accounts.google_oauth_failure")
      return
    end

    if params[:error].present? || params[:code].blank?
      redirect_to ad_accounts_path, alert: t("ad_accounts.google_oauth_failure")
      return
    end

    refresh_token = GoogleAdsApi.exchange_code(params[:code], redirect_uri: google_ads_callback_url)
    @ad_accounts = GoogleAdsApi.new(refresh_token: refresh_token).discover_accounts
                               .sort_by { |a| [ a[:status] == "ENABLED" ? 0 : 1, a[:name].to_s ] }

    if @ad_accounts.empty?
      redirect_to ad_accounts_path, alert: t("ad_accounts.google_no_accounts")
      return
    end

    session[:google_ads_refresh_token] = refresh_token
    render :select_accounts
  rescue GoogleAdsApi::Error => e
    Rails.logger.warn("Google Ads OAuth callback error: #{e.class}: #{e.message}")
    redirect_to ad_accounts_path, alert: t("ad_accounts.google_oauth_failure")
  end

  def select_accounts
    token = session.delete(:google_ads_refresh_token)
    if token.blank?
      redirect_to ad_accounts_path, alert: t("ad_accounts.google_oauth_failure")
      return
    end

    # Customer ids are digits only; anything else in the posted form is dropped.
    account_ids = Array(params[:account_ids]).map(&:to_s).grep(/\A\d+\z/)
    if account_ids.empty?
      redirect_to ad_accounts_path, alert: t("ad_accounts.no_accounts_selected")
      return
    end

    pending_group_id = session.delete(:pending_binding_group_id)
    account_ids.each do |acct_id|
      timezone = params.dig(:account_timezones, acct_id).to_s
      login_id = params.dig(:account_login_ids, acct_id).to_s
      ad_account = current_company.ad_accounts.find_or_initialize_by(platform: "google", account_id: acct_id)
      ad_account.user = current_user
      ad_account.group_id = pending_group_id if ad_account.new_record? && pending_group_id.present?
      ad_account.assign_attributes(
        account_name: params.dig(:account_names, acct_id),
        access_token: token,
        token_expires_at: nil,
        timezone: ActiveSupport::TimeZone[timezone] ? timezone : "UTC",
        login_customer_id: login_id.match?(/\A\d+\z/) ? login_id : nil
      )
      ad_account.save!

      SyncGoogleAdMetricsJob.perform_later(ad_account_id: ad_account.id, days: BACKFILL_DAYS, trigger: "manual")
    end

    redirect_to ad_accounts_path, notice: t("ad_accounts.bind_success")
  end

  private

  def google_ads_callback_url
    "#{request.base_url}/google_ads/callback"
  end
end
