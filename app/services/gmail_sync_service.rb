class GmailSyncService
  include EmailHeaderParser

  attr_reader :email_account, :gmail

  def initialize(email_account)
    @email_account = email_account
    @gmail = GmailService.new(email_account)
  end

  def sync!
    if email_account.last_history_id.present?
      incremental_sync
    else
      full_sync
    end

    email_account.update!(last_synced_at: Time.current)
  end

  private

  def full_sync
    profile = gmail.user_profile
    page_token = nil

    loop do
      result = gmail.list_threads(query: "in:inbox", page_token: page_token)
      break if result.threads.blank?

      result.threads.each do |thread_stub|
        process_thread(thread_stub.id)
      end

      page_token = result.next_page_token
      break if page_token.nil?
    end

    email_account.update!(last_history_id: profile.history_id)
  end

  def incremental_sync
    page_token = nil
    all_thread_ids = []
    latest_history_id = email_account.last_history_id

    loop do
      history_result = gmail.list_history(
        start_history_id: email_account.last_history_id,
        page_token: page_token
      )

      if history_result.history.present?
        thread_ids = history_result.history
          .flat_map(&:messages_added)
          .compact
          .map { |ma| ma.message.thread_id }

        all_thread_ids.concat(thread_ids)
      end

      latest_history_id = history_result.history_id if history_result.history_id
      page_token = history_result.next_page_token
      break if page_token.nil?
    end

    all_thread_ids.uniq.each { |thread_id| process_thread(thread_id) }
    email_account.update!(last_history_id: latest_history_id) if latest_history_id
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 404
    full_sync
  end

  def process_thread(thread_id)
    full_thread = gmail.get_thread(thread_id)
    return if full_thread.messages.blank?

    ticket = email_account.tickets.find_or_initialize_by(gmail_thread_id: thread_id)
    first_message = full_thread.messages.first
    headers = extract_headers(first_message)

    first_body = extract_body(first_message)
    customer = detect_customer(headers, email_account.email, first_body)

    ticket.assign_attributes(
      subject: headers["Subject"],
      customer_email: customer[:email] || "unknown",
      customer_name: customer[:name]
    )

    is_new = ticket.new_record?

    if is_new
      has_our_reply = full_thread.messages.any? do |msg|
        msg_from = parse_email_address(extract_headers(msg)["From"])
        msg_from&.downcase == email_account.email.downcase
      end
      ticket.status = has_our_reply ? :closed : :new_ticket
    end

    last_msg_time = nil

    full_thread.messages.each do |gmail_msg|
      msg_headers = extract_headers(gmail_msg)
      sent_time = gmail_msg.internal_date ? Time.at(gmail_msg.internal_date / 1000.0).utc : nil
      last_msg_time = sent_time if sent_time && (last_msg_time.nil? || sent_time > last_msg_time)

      message = ticket.messages.find_or_initialize_by(gmail_message_id: gmail_msg.id)
      message.assign_attributes(
        from: msg_headers["From"] || "unknown",
        to: msg_headers["To"],
        cc: msg_headers["Cc"],
        subject: msg_headers["Subject"],
        body: extract_body(gmail_msg),
        sent_at: sent_time,
        gmail_internal_date: gmail_msg.internal_date
      )
    end

    ticket.last_message_at = last_msg_time

    Ticket.transaction do
      ticket.save!
      ticket.messages.each do |message|
        message.ticket_id ||= ticket.id
        message.save! if message.new_record? || message.changed?
      end
    end

    if is_new && ticket.customer_email.present?
      begin
        ShopifyLookupService.new.lookup(ticket)
      rescue => e
        Rails.logger.error("[ShopifyLookup] Failed for Ticket##{ticket.id}: #{e.message}")
      end
    end
  end

  SHOPIFY_SENDER_PATTERNS = [
    /@shopify\.com\z/i,
    /@myshopify\.com\z/i,
    /noreply@/i,
    /no-reply@/i
  ].freeze

  def detect_customer(headers, account_email, body = nil)
    from_email = parse_email_address(headers["From"])

    # If sender looks like Shopify/system, try to extract real customer from body
    if from_email && shopify_sender?(from_email) && body.present?
      customer_from_body = extract_customer_from_body(body)
      return customer_from_body if customer_from_body[:email].present?
    end

    if from_email&.downcase != account_email.downcase
      { email: from_email, name: parse_name(headers["From"]) }
    else
      to_email = parse_email_address(headers["To"])
      { email: to_email, name: parse_name(headers["To"]) }
    end
  end

  def shopify_sender?(email)
    SHOPIFY_SENDER_PATTERNS.any? { |pattern| email.match?(pattern) }
  end

  def extract_customer_from_body(body)
    email = nil
    name = nil

    # Match email patterns in body
    email_match = body.match(/[\w.+-]+@[\w.-]+\.\w{2,}/)
    email = email_match[0] if email_match

    # Common Shopify form patterns:
    # "Name: John Doe" or "From: John Doe"
    name_match = body.match(/(?:Name|From|Customer|送信者|名前)\s*[:：]\s*(.+)/i)
    name = name_match[1].strip if name_match

    # "Email: john@example.com" — more specific email extraction
    email_field_match = body.match(/(?:Email|E-mail|メール)\s*[:：]\s*([\w.+-]+@[\w.-]+\.\w{2,})/i)
    email = email_field_match[1] if email_field_match

    { email: email, name: name }
  end

  def extract_headers(message)
    headers = {}
    message.payload&.headers&.each { |h| headers[h.name] = h.value }
    headers
  end

  def extract_body(message)
    parts = message.payload&.parts
    if parts.present?
      text_part = parts.find { |p| p.mime_type == "text/plain" }
      html_part = parts.find { |p| p.mime_type == "text/html" }
      decode_body((text_part || html_part)&.body&.data)
    else
      decode_body(message.payload&.body&.data)
    end
  end

  def decode_body(data)
    return nil if data.nil?
    Base64.urlsafe_decode64(data).force_encoding("UTF-8")
  rescue ArgumentError
    data
  end
end
