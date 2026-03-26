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

  def list_history(start_history_id:, history_types: [ "messageAdded" ], page_token: nil)
    client.list_user_histories("me", start_history_id: start_history_id, history_types: history_types, page_token: page_token)
  end

  def user_profile
    client.get_user_profile("me")
  end

  def send_message(to:, subject:, body:, thread_id: nil, message_id: nil)
    raw_message = build_raw_message(to: to, subject: subject, body: body, message_id: message_id)

    message = Google::Apis::GmailV1::Message.new(
      raw: Base64.urlsafe_encode64(raw_message),
      thread_id: thread_id
    )

    client.send_user_message("me", message)
  end

  private

  def build_raw_message(to:, subject:, body:, message_id: nil)
    headers = []
    headers << "From: #{email_account.email}"
    headers << "To: #{to}"
    headers << "Subject: #{subject}"
    headers << "Content-Type: text/plain; charset=UTF-8"
    headers << "In-Reply-To: #{message_id}" if message_id
    headers << "References: #{message_id}" if message_id
    headers << ""
    headers << body

    headers.join("\r\n")
  end

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

    raise "Token refresh failed: HTTP #{response.code} - #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    begin
      data = JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise "Token refresh failed: invalid JSON (HTTP #{response.code}): #{e.message}"
    end

    raise "Token refresh failed: #{data['error'] || 'no access_token in response'}" unless data["access_token"]

    email_account.update!(
      access_token: data["access_token"],
      token_expires_at: Time.current + data["expires_in"].to_i.seconds
    )
  end

  def token_expired?
    email_account.token_expires_at.nil? || email_account.token_expires_at <= 5.minutes.from_now
  end
end
