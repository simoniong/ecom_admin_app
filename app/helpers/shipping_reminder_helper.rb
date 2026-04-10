module ShippingReminderHelper
  def email_rule_heading(rule_type, rules)
    rule = rules[rule_type]
    days_values = rule&.parsed_thresholds&.map { |t| t[:days].to_i }&.uniq&.sort

    if rule_type == "tracking_stopped" || days_values.blank?
      t("shipping_reminders.email.rule_#{rule_type}")
    elsif days_values.size == 1
      t("shipping_reminders.email.rule_#{rule_type}", days: days_values.first)
    else
      t("shipping_reminders.email.rule_#{rule_type}", days: days_values.join("/"))
    end
  end

  def shipments_link_for_rule(rule_type, fulfillments, rules)
    rule = rules[rule_type]
    countries = rule&.parsed_thresholds&.map { |t| t[:country] } || []
    destination = countries.first if countries.size == 1

    params = {}
    params[:destination] = destination if destination

    case rule_type
    when "not_delivered"
      days = rule&.parsed_thresholds&.map { |t| t[:days].to_i }&.min
      params[:shipped_to] = days.days.ago.to_date.iso8601 if days&.positive?
    when "without_updates"
      # Filter by last event before the threshold cutoff
      days = rule&.parsed_thresholds&.map { |t| t[:days].to_i }&.min
      params[:event_to] = days.days.ago.to_date.iso8601 if days&.positive?
    when "ready_for_pickup"
      params[:status] = "AvailableForPickup"
    when "tracking_stopped"
      params[:status] = "Exception"
    end

    shipments_url(params)
  end
end
