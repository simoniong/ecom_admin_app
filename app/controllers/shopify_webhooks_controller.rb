class ShopifyWebhooksController < ActionController::API
  before_action :verify_shopify_webhook

  def receive
    topic = request.headers["X-Shopify-Topic"]
    shop_domain = request.headers["X-Shopify-Shop-Domain"]

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
      if @webhook_store
        ProcessCustomerRedactJob.perform_later(@webhook_store.id, webhook_payload)
      else
        Rails.logger.info("[ShopifyWebhook] customers/redact for unknown shop=#{shop_domain}")
      end
      head :ok
      return
    when "shop/redact"
      if @webhook_store
        ProcessShopRedactJob.perform_later(@webhook_store.id)
      else
        Rails.logger.info("[ShopifyWebhook] shop/redact for unknown shop=#{shop_domain}")
      end
      head :ok
      return
    end

    unless @webhook_store
      Rails.logger.warn("[ShopifyWebhook] Unknown shop: #{shop_domain}")
      head :not_found
      return
    end

    case topic
    when "orders/create", "orders/updated"
      ProcessShopifyOrderWebhookJob.perform_later(@webhook_store.id, webhook_payload)
    else
      Rails.logger.info("[ShopifyWebhook] Ignoring topic: #{topic}")
    end

    head :ok
  end

  private

  # Looks up the store by the shop-domain header and verifies the webhook HMAC
  # with that store's client_secret. The header is attacker-controllable, but a
  # forged shop name will not match that store's secret, so selecting the secret
  # by header is safe. An unknown shop has no actionable target, so HMAC is
  # skipped and #receive decides the response (200 for GDPR, 404 otherwise).
  def verify_shopify_webhook
    shop_domain = request.headers["X-Shopify-Shop-Domain"]
    @webhook_store = ShopifyStore.find_by(shop_domain: shop_domain)
    return if @webhook_store.nil?

    secret = @webhook_store.client_secret
    if secret.blank?
      Rails.logger.error("[ShopifyWebhook] Store #{shop_domain} has no client_secret")
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
