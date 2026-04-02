class ShopifyWebhookRegistrationService
  TOPICS = %w[orders/create orders/updated].freeze

  def initialize(shopify_store)
    @store = shopify_store
    @shopify = ShopifyService.new(shopify_store)
  end

  def call
    existing = @shopify.list_webhooks["webhooks"] || []
    existing_topics = existing.map { |w| w["topic"] }

    TOPICS.each do |topic|
      next if existing_topics.include?(topic)

      @shopify.register_webhook(topic: topic, address: webhook_url)
      Rails.logger.info("[WebhookRegistration] Registered #{topic} for #{@store.shop_domain}")
    end

    @store.update!(webhooks_registered_at: Time.current)
  end

  private

  def webhook_url
    host = ENV["APP_HOST"] || Rails.application.credentials.dig(:app, :host)
    "#{host}/shopify/webhooks"
  end
end
