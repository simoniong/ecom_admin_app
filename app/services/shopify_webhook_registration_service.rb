class ShopifyWebhookRegistrationService
  TOPICS = %w[orders/create orders/updated].freeze

  def initialize(shopify_store)
    @store = shopify_store
    @shopify = ShopifyService.new(shopify_store)
  end

  def call
    host = ENV["APP_HOST"] || Rails.application.credentials.dig(:app, :host)
    if host.blank?
      Rails.logger.error("[WebhookRegistration] APP_HOST is not configured, skipping for #{@store.shop_domain}")
      return
    end

    target_url = "#{host.chomp('/')}/shopify/webhooks"

    existing = @shopify.list_webhooks["webhooks"] || []

    TOPICS.each do |topic|
      match = existing.find { |w| w["topic"] == topic }

      if match && match["address"] != target_url
        @shopify.delete_webhook(match["id"])
        Rails.logger.info("[WebhookRegistration] Deleted stale #{topic} webhook for #{@store.shop_domain}")
        match = nil
      end

      next if match

      @shopify.register_webhook(topic: topic, address: target_url)
      Rails.logger.info("[WebhookRegistration] Registered #{topic} for #{@store.shop_domain}")
    end

    @store.update!(webhooks_registered_at: Time.current)
  end
end
