# Thin REST client for the Google Ads API: OAuth (authorization URL, code
# exchange, refresh) plus GAQL search. Plain Net::HTTP instead of the
# google-ads-googleads gem — we only read a handful of report rows, and the
# gem drags in gRPC.
#
# Every request carries the developer token. Accounts reached through a
# manager account (MCC) also need the manager's id in login-customer-id, or
# the API answers USER_PERMISSION_DENIED.
class GoogleAdsApi
  VERSION   = "v25"
  BASE_URL  = "https://googleads.googleapis.com/#{VERSION}".freeze
  AUTH_URL  = "https://accounts.google.com/o/oauth2/v2/auth".freeze
  TOKEN_URL = "https://oauth2.googleapis.com/token".freeze
  SCOPE     = "https://www.googleapis.com/auth/adwords".freeze

  class Error < StandardError; end
  # The refresh token was revoked or expired — only reconnecting fixes it.
  class AuthError < Error; end

  def self.client_id
    ENV["GOOGLE_CLIENT_ID"] || Rails.application.credentials.dig(:google, :client_id)
  end

  def self.client_secret
    ENV["GOOGLE_CLIENT_SECRET"] || Rails.application.credentials.dig(:google, :client_secret)
  end

  def self.developer_token
    ENV["GOOGLE_ADS_DEVELOPER_TOKEN"] || Rails.application.credentials.dig(:google_ads, :developer_token)
  end

  # prompt=consent makes Google return a refresh token even when the user has
  # granted this client before; without it a reconnect comes back with none.
  def self.authorization_url(redirect_uri:, state:)
    query = URI.encode_www_form(
      client_id: client_id, redirect_uri: redirect_uri, response_type: "code",
      scope: SCOPE, access_type: "offline", prompt: "consent", state: state
    )
    "#{AUTH_URL}?#{query}"
  end

  def self.exchange_code(code, redirect_uri:)
    body = token_request(grant_type: "authorization_code", code: code, redirect_uri: redirect_uri)
    body["refresh_token"].presence || raise(AuthError, "no refresh token returned")
  end

  def self.token_request(params)
    response = Net::HTTP.post_form(URI(TOKEN_URL), params.merge(client_id: client_id, client_secret: client_secret))
    body = JSON.parse(response.body.presence || "{}")
    return body if response.is_a?(Net::HTTPSuccess)

    error = body["error"].to_s
    raise(error == "invalid_grant" ? AuthError : Error, "token request failed: #{error.presence || response.code}")
  end

  def initialize(refresh_token:, login_customer_id: nil)
    @refresh_token = refresh_token
    @login_customer_id = login_customer_id
  end

  def access_token
    @access_token ||= self.class.token_request(grant_type: "refresh_token", refresh_token: @refresh_token).fetch("access_token")
  end

  # Customer ids the authorizing Google user can reach directly — for a user
  # who manages everything through an MCC, that's just the MCC itself.
  def accessible_customer_ids
    get("customers:listAccessibleCustomers").fetch("resourceNames", []).map { |name| name.delete_prefix("customers/") }
  end

  # Runs a GAQL query and returns every result row, following pagination.
  def search(customer_id, query, login_customer_id: @login_customer_id)
    rows = []
    page_token = nil
    loop do
      payload = { query: query }
      payload[:pageToken] = page_token if page_token
      body = post("customers/#{customer_id}/googleAds:search", payload, login_customer_id: login_customer_id)
      rows.concat(body.fetch("results", []))
      page_token = body["nextPageToken"].presence
      break unless page_token
    end
    rows
  end

  # Every non-manager account the user can report on: accounts reached
  # directly, plus the clients under each MCC (with that MCC as their
  # login_customer_id). An account that is unreachable — cancelled, or the
  # link was removed — is skipped rather than failing the whole list.
  def discover_accounts
    accounts = accessible_customer_ids.flat_map do |id|
      customer = search(id, "SELECT customer.id, customer.descriptive_name, customer.manager, customer.time_zone, " \
                            "customer.currency_code, customer.status FROM customer", login_customer_id: nil)
                   .first&.fetch("customer", nil)
      next [] unless customer

      if customer["manager"]
        search(id, "SELECT customer_client.id, customer_client.descriptive_name, customer_client.time_zone, " \
                   "customer_client.currency_code, customer_client.status FROM customer_client " \
                   "WHERE customer_client.manager = FALSE", login_customer_id: id)
          .map { |row| account_hash(row["customerClient"], login_customer_id: id) }
      else
        [ account_hash(customer, login_customer_id: nil) ]
      end
    rescue Error => e
      Rails.logger.warn("[GoogleAdsApi] skipping customer #{id}: #{e.message}")
      []
    end
    accounts.uniq { |a| a[:id] }
  end

  private

  def account_hash(data, login_customer_id:)
    {
      id: data["id"].to_s, name: data["descriptiveName"], time_zone: data["timeZone"],
      currency: data["currencyCode"], status: data["status"], login_customer_id: login_customer_id
    }
  end

  def get(path)
    request(Net::HTTP::Get.new(URI("#{BASE_URL}/#{path}")))
  end

  def post(path, payload, login_customer_id:)
    req = Net::HTTP::Post.new(URI("#{BASE_URL}/#{path}"))
    req["Content-Type"] = "application/json"
    req["login-customer-id"] = login_customer_id.to_s if login_customer_id.present?
    req.body = payload.to_json
    request(req)
  end

  def request(req)
    req["Authorization"] = "Bearer #{access_token}"
    req["developer-token"] = self.class.developer_token.to_s
    uri = req.uri
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 60) { |http| http.request(req) }
    body = JSON.parse(response.body.presence || "{}")
    return body if response.is_a?(Net::HTTPSuccess)

    raise Error, "#{response.code} #{body.dig('error', 'status')}: #{body.dig('error', 'message')}"
  end
end
