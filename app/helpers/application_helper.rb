module ApplicationHelper
  def parse_email_address(header_value)
    return nil if header_value.blank?
    match = header_value.match(/<([^>]+)>/)
    match ? match[1] : header_value.strip
  end

  # Splits email body into [new_content, quoted_content]
  # Detects "On ... wrote:" pattern and lines starting with ">"
  def split_email_body(body)
    return [ body, nil ] if body.blank?

    lines = body.lines
    split_index = nil

    lines.each_with_index do |line, i|
      # Match "On <date> <person> wrote:" pattern
      if line.match?(/\AOn .+ wrote:\s*\z/i)
        split_index = i
        break
      end

      # Match beginning of quoted block (line starting with ">")
      if line.match?(/\A>/) && (split_index.nil?)
        # Check it's not just a single ">" in the middle of content
        remaining = lines[i..]
        quoted_count = remaining.take_while { |l| l.match?(/\A>/) || l.strip.empty? }.size
        if quoted_count >= 2
          split_index = i
          break
        end
      end
    end

    if split_index
      new_content = lines[0...split_index].join.strip
      quoted_content = lines[split_index..].join.strip
      [ new_content, quoted_content.presence ]
    else
      [ body.strip, nil ]
    end
  end
end
