class ShopifyOauthController < AdminController
  SHOP_DOMAIN_FORMAT = /\A[\w-]+\.myshopify\.com\z/

  def auth
    shop = params[:shop].to_s.strip.downcase
    client_id = params[:client_id].to_s.strip
    client_secret = params[:client_secret].to_s.strip

    unless shop.match?(SHOP_DOMAIN_FORMAT)
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    if client_id.blank? || client_secret.blank?
      redirect_to shopify_stores_path, alert: t("shopify_stores.credentials_required")
      return
    end

    if company_has_groups?
      group = resolve_binding_group(params[:group_id])
      if group.nil?
        redirect_to shopify_stores_path, alert: t("shopify_stores.group_required")
        return
      end
      session[:pending_binding_group_id] = group.id
    else
      session.delete(:pending_binding_group_id)
    end

    nonce = SecureRandom.hex(16)
    session[:shopify_oauth_nonce] = nonce
    session[:shopify_pending_client_id] = client_id
    session[:shopify_pending_client_secret] = client_secret
    session[:shopify_pending_shop] = shop

    scopes = "read_products,read_customers,read_all_orders,read_fulfillments,read_analytics,write_webhooks,read_merchant_managed_fulfillment_orders,write_merchant_managed_fulfillment_orders"
    redirect_uri = shopify_callback_url(locale: nil)

    authorize_url = "https://#{shop}/admin/oauth/authorize?" + {
      client_id: client_id,
      scope: scopes,
      redirect_uri: redirect_uri,
      state: nonce
    }.to_query

    redirect_to authorize_url, allow_other_host: true
  end

  def callback
    shop = params[:shop].to_s.strip.downcase
    code = params[:code]
    state = params[:state]
    hmac = params[:hmac]

    client_id = session[:shopify_pending_client_id]
    client_secret = session[:shopify_pending_client_secret]
    pending_shop = session[:shopify_pending_shop]

    if client_id.blank? || client_secret.blank? || pending_shop.blank?
      clear_pending_session
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    unless shop.match?(SHOP_DOMAIN_FORMAT) && code.present?
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    unless shop == pending_shop
      clear_pending_session
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    session_nonce = session.delete(:shopify_oauth_nonce).to_s
    if session_nonce.present?
      unless state.present? && ActiveSupport::SecurityUtils.secure_compare(state.to_s, session_nonce)
        redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
        return
      end
    end

    unless verify_hmac(hmac, request.query_parameters.except("hmac"), client_secret)
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    access_token_response = exchange_code_for_token(shop, code, client_id, client_secret)

    unless access_token_response
      clear_pending_session
      redirect_to shopify_stores_path, alert: t("shopify_stores.bind_failure")
      return
    end

    store = current_company.shopify_stores.find_or_initialize_by(shop_domain: shop)
    store.user = current_user
    if store.new_record? && (pending_group_id = session.delete(:pending_binding_group_id)).present?
      store.group_id = pending_group_id
    end
    shop_info = fetch_shop_info(shop, access_token_response["access_token"])
    store.assign_attributes(
      access_token: access_token_response["access_token"],
      client_id: client_id,
      client_secret: client_secret,
      scopes: access_token_response["scope"],
      name: shop_info["name"].presence || store.name,
      timezone: shop_info["iana_timezone"].presence || "UTC",
      installed_at: store.installed_at || Time.current
    )

    clear_pending_session

    if store.save
      SyncAllShopifyOrdersJob.perform_later(store.id)
      RegisterShopifyWebhooksJob.perform_later(store.id)
      BackfillShopifyMetricsJob.perform_later(store.id)
      redirect_to shopify_stores_path, notice: t("shopify_stores.bind_success")
    else
      alert = store.errors[:shop_domain].any? ? t("shopify_stores.already_bound") : t("shopify_stores.bind_failure")
      redirect_to shopify_stores_path, alert: alert
    end
  end

  private

  def clear_pending_session
    session.delete(:shopify_pending_client_id)
    session.delete(:shopify_pending_client_secret)
    session.delete(:shopify_pending_shop)
  end

  def verify_hmac(hmac, query_params, client_secret)
    return false if hmac.blank? || client_secret.blank?

    message = query_params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
    digest = OpenSSL::HMAC.hexdigest("SHA256", client_secret, message)
    return false unless hmac.bytesize == digest.bytesize

    ActiveSupport::SecurityUtils.secure_compare(digest, hmac)
  end

  def fetch_shop_info(shop, access_token)
    response = HTTParty.get(
      "https://#{shop}/admin/api/2024-10/shop.json",
      query: { fields: "name,iana_timezone" },
      headers: { "X-Shopify-Access-Token" => access_token, "Content-Type" => "application/json" }
    )
    return {} unless response.success?
    response.parsed_response["shop"] || {}
  rescue
    {}
  end

  def exchange_code_for_token(shop, code, client_id, client_secret)
    response = HTTParty.post(
      "https://#{shop}/admin/oauth/access_token",
      body: {
        client_id: client_id,
        client_secret: client_secret,
        code: code
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    return nil unless response.success?

    response.parsed_response
  end
end
