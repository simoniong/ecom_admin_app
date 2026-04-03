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

  def html_content?(text)
    return false if text.blank?
    text.match?(/<\s*(html|body|div|p|table|br|span|a|img|head|style)\b/i)
  end

  def render_message_body(body)
    if html_content?(body)
      # Render HTML in sandboxed iframe for security
      tag.iframe(
        srcdoc: body,
        sandbox: "",
        class: "w-full border-0 rounded",
        style: "min-height: 300px; max-height: 600px;",
        loading: "lazy",
        title: "Email message",
        data: { controller: "autosize-iframe" }
      )
    else
      new_content, quoted_content = split_email_body(body)
      html = tag.div(new_content, class: "text-sm text-gray-800 whitespace-pre-wrap break-words")

      if quoted_content.present?
        html += render_quoted_content(quoted_content)
      end

      html
    end
  end

  def render_quoted_content(quoted_content) # :nodoc:
    tag.div(data: { controller: "collapsible" }, class: "mt-2") do
      button = tag.button(
        data: { action: "click->collapsible#toggle" },
        class: "text-xs text-gray-400 hover:text-gray-600 flex items-center gap-1"
      ) do
        tag.span("···") +
        tag.svg(
          tag.path("", stroke_linecap: "round", stroke_linejoin: "round", d: "m19.5 8.25-7.5 7.5-7.5-7.5"),
          data: { collapsible_target: "icon" },
          class: "w-3 h-3 transition-transform",
          xmlns: "http://www.w3.org/2000/svg", fill: "none", viewBox: "0 0 24 24",
          stroke_width: "1.5", stroke: "currentColor", aria_hidden: "true"
        )
      end

      content = tag.div(
        quoted_content,
        data: { collapsible_target: "content" },
        class: "hidden mt-1 pl-3 border-l-2 border-gray-200 text-xs text-gray-500 whitespace-pre-wrap break-words"
      )

      button + content
    end
  end

  def pagination_range(current, total, window: 2)
    return (1..total).to_a if total <= (window * 2 + 5)

    pages = []
    pages << 1
    left = [ current - window, 2 ].max
    right = [ current + window, total - 1 ].min

    pages << :gap if left > 2
    pages.concat((left..right).to_a)
    pages << :gap if right < total - 1
    pages << total if total > 1
    pages
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
