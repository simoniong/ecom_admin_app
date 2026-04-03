api_key = ENV["SHOPIFY_CLIENT_ID"] || Rails.application.credentials.dig(:shopify, :client_id)
api_secret = ENV["SHOPIFY_CLIENT_SECRET"] || Rails.application.credentials.dig(:shopify, :client_secret)

if api_key.present? && api_secret.present?
  ShopifyAPI::Context.setup(
    api_key: api_key,
    api_secret_key: api_secret,
    scope: "read_products,read_customers,read_all_orders,read_fulfillments,read_analytics",
    is_embedded: false,
    api_version: "2024-10",
    is_private: false
  )
end
