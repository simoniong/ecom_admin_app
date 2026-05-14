# The app authenticates with Shopify per-store: each ShopifyStore holds its own
# OAuth credentials. ShopifyAPI is only used for token-authenticated Admin
# GraphQL calls (see ShopifyAnalyticsService), which carry the store's own
# access_token and never read api_key / api_secret_key. OAuth and webhook HMAC
# verification are handled directly in ShopifyOauthController /
# ShopifyWebhooksController, not through this gem.
#
# ShopifyAPI::Context.setup must still run so the GraphQL client can read
# Context.api_version / logger / api_host — but the key and secret it receives
# are deliberate, unused placeholders. There is no global Shopify app.
ShopifyAPI::Context.setup(
  api_key: "unused-per-store-credentials",
  api_secret_key: "unused-per-store-credentials",
  scope: "read_products,read_customers,read_all_orders,read_fulfillments,read_analytics",
  is_embedded: false,
  api_version: "2024-10",
  is_private: false
)
