class GmailService
  GOOGLE_TOKEN_URI = "https://oauth2.googleapis.com/token"

  attr_reader :email_account

  def initialize(email_account)
    @email_account = email_account
  end

  def list_threads(query: nil, page_token: nil, max_results: 100)
    client.list_user_threads("me", q: query, page_token: page_token, max_results: max_results)
  end

  def get_thread(thread_id)
    client.get_user_thread("me", thread_id, format: "full")
  end

  def list_history(start_history_id:, history_types: [ "messageAdded" ])
    client.list_user_histories("me", start_history_id: start_history_id, history_types: history_types)
  end

  def user_profile
    client.get_user_profile("me")
  end

  private

  def client
    @client ||= build_client
  end

  def build_client
    refresh_token_if_needed!

    service = Google::Apis::GmailV1::GmailService.new
    service.authorization = Signet::OAuth2::Client.new(
      access_token: email_account.access_token,
      expires_at: email_account.token_expires_at
    )
    service
  end

  def refresh_token_if_needed!
    return unless token_expired?

    response = Net::HTTP.post_form(
      URI(GOOGLE_TOKEN_URI),
      client_id: Rails.application.credentials.dig(:google, :client_id),
      client_secret: Rails.application.credentials.dig(:google, :client_secret),
      refresh_token: email_account.refresh_token,
      grant_type: "refresh_token"
    )

    data = JSON.parse(response.body)
    raise "Token refresh failed: #{data['error']}" unless data["access_token"]

    email_account.update!(
      access_token: data["access_token"],
      token_expires_at: Time.current + data["expires_in"].to_i.seconds
    )
  end

  def token_expired?
    email_account.token_expires_at.nil? || email_account.token_expires_at <= 5.minutes.from_now
  end
end
