class MetaAdsService
  def initialize(ad_account)
    @ad_account = ad_account
    @graph = build_graph
  end

  def sync_date_range(start_date, end_date)
    insights = @graph.get_connections(
      @ad_account.account_id, "insights",
      fields: "spend,impressions,clicks,actions,action_values",
      time_range: { since: start_date.iso8601, until: end_date.iso8601 },
      time_increment: 1,
      level: "account"
    )

    # Koala paginates by default (25 per page). Fetch all pages.
    all_insights = insights.to_a
    if insights.respond_to?(:next_page)
      while (next_page = insights.next_page)
        all_insights.concat(next_page)
        insights = next_page
      end
    end

    all_insights.each do |day_data|
      date = Date.parse(day_data["date_start"])
      metric = @ad_account.ad_daily_metrics.find_or_initialize_by(date: date)
      conversions = extract_action_count(day_data["actions"], "offsite_conversion.fb_pixel_purchase")
      conversion_value = extract_action_value(day_data["action_values"], "offsite_conversion.fb_pixel_purchase")

      metric.assign_attributes(
        spend: day_data["spend"].to_d,
        impressions: day_data["impressions"].to_i,
        clicks: day_data["clicks"].to_i,
        conversions: conversions,
        conversion_value: conversion_value
      )
      metric.save!
    end
  end

  def refresh_token_if_needed!
    return unless @ad_account.token_expiring_soon?

    oauth = Koala::Facebook::OAuth.new(
      ENV["META_APP_ID"] || Rails.application.credentials.dig(:meta, :app_id),
      ENV["META_APP_SECRET"] || Rails.application.credentials.dig(:meta, :app_secret)
    )
    new_info = oauth.exchange_access_token_info(@ad_account.access_token)
    @ad_account.update!(
      access_token: new_info["access_token"],
      token_expires_at: Time.current + new_info["expires_in"].to_i.seconds
    )
    @graph = build_graph
  end

  private

  def build_graph
    Koala::Facebook::API.new(@ad_account.access_token)
  end

  def extract_action_count(actions, action_type)
    return 0 if actions.blank?
    actions.find { |a| a["action_type"] == action_type }&.dig("value").to_i
  end

  def extract_action_value(action_values, action_type)
    return 0 if action_values.blank?
    action_values.find { |a| a["action_type"] == action_type }&.dig("value").to_d
  end
end
