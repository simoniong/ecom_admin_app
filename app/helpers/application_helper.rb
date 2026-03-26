module ApplicationHelper
  include EmailHeaderParser

  def ticket_status_badge_classes(status)
    case status
    when "new_ticket" then "bg-blue-100 text-blue-800"
    when "draft" then "bg-yellow-100 text-yellow-800"
    when "draft_confirmed" then "bg-green-100 text-green-800"
    when "closed" then "bg-gray-100 text-gray-800"
    else "bg-gray-100 text-gray-800"
    end
  end

  def split_email_body(body)
    return [ body, nil ] if body.blank?

    lines = body.lines
    split_index = nil

    lines.each_with_index do |line, i|
      if line.match?(/\AOn .+ wrote:\s*\z/i)
        split_index = i
        break
      end

      if line.match?(/\A>/) && split_index.nil?
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
