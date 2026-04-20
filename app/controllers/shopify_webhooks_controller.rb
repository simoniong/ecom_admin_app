class ShopifyWebhooksController < ActionController::API
  before_action :verify_shopify_webhook

  def receive
    topic = request.headers["X-Shopify-Topic"]
    shop_domain = request.headers["X-Shopify-Shop-Domain"]

    store = ShopifyStore.find_by(shop_domain: shop_domain)

    # GDPR compliance webhooks must always return 200, even if the store is unknown
    # (e.g., already uninstalled/deleted). Otherwise Shopify retries indefinitely.
    case topic
    when "customers/data_request"
      customer_id = webhook_payload.dig("customer", "id")
      orders_count = Array(webhook_payload["orders_requested"]).size
      Rails.logger.info("[ShopifyWebhook] customers/data_request shop=#{shop_domain} customer_id=#{customer_id} orders_requested=#{orders_count}")
      head :ok
      return
    when "customers/redact"
      if store
        ProcessCustomerRedactJob.perform_later(store.id, webhook_payload)
      else
        Rails.logger.info("[ShopifyWebhook] customers/redact for unknown shop=#{shop_domain}")
      end
      head :ok
      return
    when "shop/redact"
      if store
        ProcessShopRedactJob.perform_later(store.id)
      else
        Rails.logger.info("[ShopifyWebhook] shop/redact for unknown shop=#{shop_domain}")
      end
      head :ok
      return
    end

    unless store
      Rails.logger.warn("[ShopifyWebhook] Unknown shop: #{shop_domain}")
      head :not_found
      return
    end

    case topic
    when "orders/create", "orders/updated"
      ProcessShopifyOrderWebhookJob.perform_later(store.id, webhook_payload)
    else
      Rails.logger.info("[ShopifyWebhook] Ignoring topic: #{topic}")
    end

    head :ok
  end

  private

  def verify_shopify_webhook
    secret = ENV["SHOPIFY_CLIENT_SECRET"] || Rails.application.credentials.dig(:shopify, :client_secret)
    if secret.blank?
      Rails.logger.error("[ShopifyWebhook] SHOPIFY_CLIENT_SECRET is not configured")
      head :unauthorized
      return
    end

    request.body.rewind
    body = request.body.read
    request.body.rewind

    digest = OpenSSL::HMAC.digest("SHA256", secret, body)
    computed_hmac = Base64.strict_encode64(digest)
    header_hmac = request.headers["X-Shopify-Hmac-Sha256"]

    unless header_hmac.present? && ActiveSupport::SecurityUtils.secure_compare(computed_hmac, header_hmac)
      head :unauthorized
    end
  end

  def webhook_payload
    @webhook_payload ||= JSON.parse(request.body.tap(&:rewind).read)
  end
end
