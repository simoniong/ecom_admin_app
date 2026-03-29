class ShopifyOauthController < AdminController
  SHOP_DOMAIN_FORMAT = /\A[\w-]+\.myshopify\.com\z/

  def auth
    shop = params[:shop].to_s.strip.downcase

    unless shop.match?(SHOP_DOMAIN_FORMAT)
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    nonce = SecureRandom.hex(16)
    session[:shopify_oauth_nonce] = nonce

    client_id = ENV["SHOPIFY_CLIENT_ID"] || Rails.application.credentials.dig(:shopify, :client_id)

    if client_id.blank?
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    scopes = "read_products,read_customers,read_orders,read_fulfillments,read_analytics"
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

    unless shop.match?(SHOP_DOMAIN_FORMAT) && code.present? && state.present?
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    unless ActiveSupport::SecurityUtils.secure_compare(state, session.delete(:shopify_oauth_nonce).to_s)
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    unless verify_hmac(hmac, request.query_parameters.except("hmac"))
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    access_token_response = exchange_code_for_token(shop, code)

    unless access_token_response
      redirect_to shopify_stores_path, alert: t("shopify_stores.bind_failure")
      return
    end

    store = current_user.shopify_stores.find_or_initialize_by(shop_domain: shop)
    store.assign_attributes(
      access_token: access_token_response["access_token"],
      scopes: access_token_response["scope"],
      timezone: fetch_shop_timezone(shop, access_token_response["access_token"]),
      installed_at: store.installed_at || Time.current
    )

    if store.save
      redirect_to shopify_stores_path, notice: t("shopify_stores.bind_success")
    else
      redirect_to shopify_stores_path, alert: t("shopify_stores.bind_failure")
    end
  end

  private

  def verify_hmac(hmac, query_params)
    return false if hmac.blank?

    secret = ENV["SHOPIFY_CLIENT_SECRET"] || Rails.application.credentials.dig(:shopify, :client_secret)
    return false if secret.blank?

    message = query_params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, message)
    return false unless hmac.bytesize == digest.bytesize

    ActiveSupport::SecurityUtils.secure_compare(digest, hmac)
  end

  def fetch_shop_timezone(shop, access_token)
    response = HTTParty.get(
      "https://#{shop}/admin/api/2024-10/shop.json",
      query: { fields: "iana_timezone" },
      headers: { "X-Shopify-Access-Token" => access_token, "Content-Type" => "application/json" }
    )
    return "UTC" unless response.success?
    response.parsed_response.dig("shop", "iana_timezone") || "UTC"
  rescue
    "UTC"
  end

  def exchange_code_for_token(shop, code)
    client_id = ENV["SHOPIFY_CLIENT_ID"] || Rails.application.credentials.dig(:shopify, :client_id)
    client_secret = ENV["SHOPIFY_CLIENT_SECRET"] || Rails.application.credentials.dig(:shopify, :client_secret)

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
