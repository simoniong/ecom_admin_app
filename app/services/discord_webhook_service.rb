class DiscordWebhookService
  class DeliveryError < StandardError; end

  def self.notify_new_ticket(ticket)
    mention = ticket.email_account.discord_agent_mention.presence
    content = [ mention, "新 ticket，請生成 draft。Ticket ID: #{ticket.id}" ].compact.join(" ")
    send_message(content)
  end

  def self.notify_revise_draft(ticket, message)
    mention = ticket.email_account.discord_agent_mention.presence
    content = [ mention, "Ticket ID: #{ticket.id}, #{message}" ].compact.join(" ")
    send_message(content)
  end

  def self.send_message(content)
    webhook_url = ENV["DISCORD_WEBHOOK_URL"]
    return if webhook_url.blank?

    uri = URI.parse(webhook_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5

    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"
    request.body = {
      content: content,
      allowed_mentions: { parse: %w[users roles] }
    }.to_json

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPNoContent)
      raise DeliveryError, "Discord webhook failed: #{response.code} #{response.body}"
    end
  end

  private_class_method :send_message
end
