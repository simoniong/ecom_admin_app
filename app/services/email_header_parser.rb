module EmailHeaderParser
  def parse_email_address(header_value)
    return nil if header_value.blank?
    match = header_value.match(/<([^>]+)>/)
    match ? match[1] : header_value.strip
  end

  def parse_name(header_value)
    return nil if header_value.blank?
    match = header_value.match(/\A\s*"?([^"<]+)"?\s*</)
    match ? match[1].strip : nil
  end
end
