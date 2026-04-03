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
    has_failures = false

    loop do
      result = gmail.list_threads(query: "in:inbox", page_token: page_token)
      break if result.threads.blank?

      result.threads.each do |thread_stub|
        process_thread(thread_stub.id)
      rescue => e
        if e.is_a?(Google::Apis::ClientError) && e.status_code == 404
          Rails.logger.warn("[GmailSync] Skipping deleted thread #{thread_stub.id}")
        else
          has_failures = true
          Rails.logger.error("[GmailSync] Failed to process thread #{thread_stub.id}: #{e.class} - #{e.message}")
        end
      end

      page_token = result.next_page_token
      break if page_token.nil?
    end

    # Don't advance history_id on transient failures so the next sync retries
    # via full_sync again (last_history_id stays nil/stale → same path).
    email_account.update!(last_history_id: profile.history_id) unless has_failures
  end

  def incremental_sync
    page_token = nil
    all_thread_ids = []
    latest_history_id = email_account.last_history_id

    begin
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
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 404
      email_account.update!(last_history_id: nil)
      full_sync
      return
    end

    has_failures = false

    all_thread_ids.uniq.each do |thread_id|
      process_thread(thread_id)
    rescue => e
      if e.is_a?(Google::Apis::ClientError) && e.status_code == 404
        Rails.logger.warn("[GmailSync] Skipping deleted thread #{thread_id}")
      else
        has_failures = true
        Rails.logger.error("[GmailSync] Failed to process thread #{thread_id}: #{e.class} - #{e.message}")
      end
    end

    # Only advance history_id when all threads succeeded; otherwise the next
    # sync retries from the same point so transient failures get another chance.
    # Thread-level 404s (deleted threads) are skipped and don't count as failures.
    email_account.update!(last_history_id: latest_history_id) if latest_history_id && !has_failures
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

    # Story 7/8: Reopen closed tickets on new customer reply, keep closed on our reply
    if !is_new && ticket.closed?
      new_messages = ticket.messages.select(&:new_record?)
      if new_messages.any?
        latest_new_msg = new_messages.max_by { |m| m.sent_at || Time.at(0) }
        latest_from = parse_email_address(latest_new_msg&.from)

        if latest_from.present? && latest_from.include?("@") && latest_from.downcase != email_account.email.downcase
          # Customer replied → reopen
          ticket.status = :new_ticket
          ticket.draft_reply = nil
          ticket.draft_reply_at = nil
          ticket.scheduled_send_at = nil
          ticket.scheduled_job_id = nil
        end
        # Our reply or unknown sender → stay closed
      end
    end

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
    find_body_in_parts(message.payload)
  end

  def find_body_in_parts(part)
    return nil if part.nil?

    # Leaf node with body data
    if part.parts.blank?
      return decode_body(part.body&.data) if part.body&.data.present? && (part.mime_type.nil? || part.mime_type.start_with?("text/"))
      return nil
    end

    # Prefer text/plain, fall back to text/html, recurse into multipart/*
    text_part = part.parts.find { |p| p.mime_type == "text/plain" }
    return decode_body(text_part.body&.data) if text_part&.body&.data.present?

    html_part = part.parts.find { |p| p.mime_type == "text/html" }
    return decode_body(html_part.body&.data) if html_part&.body&.data.present?

    # Recurse into nested multipart parts (e.g. multipart/alternative inside multipart/mixed)
    part.parts.each do |sub_part|
      body = find_body_in_parts(sub_part)
      return body if body.present?
    end

    nil
  end

  def decode_body(data)
    return nil if data.nil?
    decoded = Base64.urlsafe_decode64(data)
    decoded.force_encoding("UTF-8")
    decoded.valid_encoding? ? decoded : decoded.encode("UTF-8", "BINARY", invalid: :replace, undef: :replace, replace: "")
  rescue ArgumentError
    data.force_encoding("UTF-8")
    data.valid_encoding? ? data : data.encode("UTF-8", "BINARY", invalid: :replace, undef: :replace, replace: "")
  end
end
