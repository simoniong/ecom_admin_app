module ApplicationHelper
  def parse_email_address(header_value)
    return nil if header_value.blank?
    match = header_value.match(/<([^>]+)>/)
    match ? match[1] : header_value.strip
  end
end
