class MetaAdsService
  def initialize(ad_account)
    @ad_account = ad_account
    @graph = build_graph
  end

  def sync_date_range(start_date, end_date)
    all_insights = fetch_all_pages(
      @ad_account.account_id, "insights",
      fields: "spend,impressions,clicks,actions,action_values",
      time_range: { since: start_date.iso8601, until: end_date.iso8601 },
      time_increment: 1,
      level: "account"
    )

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

  def sync_campaigns
    campaigns_data = fetch_all_pages(
      @ad_account.account_id, "campaigns",
      fields: "id,name,status,daily_budget,effective_status"
    )

    campaigns_data.each do |data|
      campaign = @ad_account.ad_campaigns.find_or_initialize_by(campaign_id: data["id"])
      campaign.assign_attributes(
        campaign_name: data["name"],
        status: map_campaign_status(data["effective_status"]),
        daily_budget: ((data["daily_budget"].presence || 0).to_d / 100) # Meta returns cents
      )
      campaign.save!
    end
  end

  def sync_campaign_insights(start_date, end_date)
    @ad_account.ad_campaigns.find_each do |campaign|
      insights = fetch_all_pages(
        campaign.campaign_id, "insights",
        fields: "spend,impressions,clicks,actions,action_values",
        time_range: { since: start_date.iso8601, until: end_date.iso8601 },
        time_increment: 1
      )

      insights.each do |day_data|
        date = Date.parse(day_data["date_start"])
        metric = campaign.ad_campaign_daily_metrics.find_or_initialize_by(date: date)
        metric.assign_attributes(
          impressions: day_data["impressions"].to_i,
          clicks: day_data["clicks"].to_i,
          add_to_cart: extract_action_count(day_data["actions"], "offsite_conversion.fb_pixel_add_to_cart"),
          checkout_initiated: extract_action_count(day_data["actions"], "offsite_conversion.fb_pixel_initiate_checkout"),
          purchases: extract_action_count(day_data["actions"], "offsite_conversion.fb_pixel_purchase"),
          spend: day_data["spend"].to_d,
          conversion_value: extract_action_value(day_data["action_values"], "offsite_conversion.fb_pixel_purchase")
        )
        metric.save!
      end
    rescue Koala::Facebook::ClientError => e
      Rails.logger.error("[SyncCampaignInsights] campaign=#{campaign.campaign_id}: #{e.message}")
    end
  end

  private

  def fetch_all_pages(node, edge, **params)
    page = @graph.get_connections(node, edge, **params)
    results = page.to_a
    if page.respond_to?(:next_page)
      while (next_page = page.next_page)
        results.concat(next_page)
        page = next_page
      end
    end
    results
  end

  def map_campaign_status(effective_status)
    case effective_status&.upcase
    when "ACTIVE" then "active"
    when "PAUSED", "CAMPAIGN_PAUSED", "ADSET_PAUSED" then "paused"
    when "DELETED", "ARCHIVED" then "deleted"
    else "paused"
    end
  end

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
