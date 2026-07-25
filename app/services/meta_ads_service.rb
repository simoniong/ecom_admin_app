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

  AD_FIELDS = "id,name,adset_id,campaign_id,effective_status," \
              "creative{id,video_id,image_hash,thumbnail_url,object_story_spec,asset_feed_spec}".freeze

  def sync_ad_units
    ads = fetch_all_pages(@ad_account.account_id, "ads", fields: AD_FIELDS, limit: 500)
    campaign_ids = @ad_account.ad_campaigns.pluck(:campaign_id, :id).to_h

    ads.each do |data|
      resolved = resolve_asset(data["creative"] || {})
      creative = find_or_create_creative(resolved, data["name"])

      unit = @ad_account.ad_units.find_or_initialize_by(ad_id: data["id"])
      unit.assign_attributes(
        ad_name: data["name"],
        adset_id: data["adset_id"],
        ad_campaign_id: campaign_ids[data["campaign_id"]],
        status: map_campaign_status(data["effective_status"]),
        multi_asset: resolved[:multi_asset],
        ad_creative: creative
      )
      unit.save!

      if creative.nil? && !resolved[:multi_asset]
        Rails.logger.warn("[SyncAdUnits] unresolved creative shape ad=#{data['id']} account=#{@ad_account.account_id}")
      end
    end
  end

  INSIGHT_FIELDS = %w[
    ad_id spend impressions clicks inline_link_clicks actions action_values
    video_continuous_2_sec_watched_actions
    video_p25_watched_actions video_p50_watched_actions
    video_p75_watched_actions video_p95_watched_actions video_p100_watched_actions
  ].join(",").freeze

  # Fetches one date range and returns parsed rows. Deliberately performs no
  # writes: the caller persists them together with the coverage advance inside
  # a single transaction (spec §5.6), and an HTTP call must not sit inside one.
  def fetch_ad_insights(start_date, end_date)
    rows = fetch_all_pages(
      @ad_account.account_id, "insights",
      fields: INSIGHT_FIELDS,
      level: "ad",
      time_increment: 1,
      use_account_attribution_setting: true,
      time_range: { since: start_date.iso8601, until: end_date.iso8601 },
      limit: 500
    )

    rows.map do |row|
      {
        ad_id: row["ad_id"],
        date: Date.parse(row["date_start"]),
        spend: row["spend"].to_d,
        impressions: row["impressions"].to_i,
        clicks: row["clicks"].to_i,
        inline_link_clicks: row["inline_link_clicks"].to_i,
        video_continuous_2_sec_watched: extract_video_metric(row["video_continuous_2_sec_watched_actions"]),
        video_p25_watched: extract_video_metric(row["video_p25_watched_actions"]),
        video_p50_watched: extract_video_metric(row["video_p50_watched_actions"]),
        video_p75_watched: extract_video_metric(row["video_p75_watched_actions"]),
        video_p95_watched: extract_video_metric(row["video_p95_watched_actions"]),
        video_p100_watched: extract_video_metric(row["video_p100_watched_actions"]),
        add_to_cart: extract_action_count(row["actions"], "offsite_conversion.fb_pixel_add_to_cart"),
        checkout_initiated: extract_action_count(row["actions"], "offsite_conversion.fb_pixel_initiate_checkout"),
        purchases: extract_action_count(row["actions"], "offsite_conversion.fb_pixel_purchase"),
        conversion_value: extract_action_value(row["action_values"], "offsite_conversion.fb_pixel_purchase")
      }
    end
  end

  private

  # Resolution order per spec §5.1. First match wins; the multi-asset check
  # must stay first so a residual video_id on an Advantage+ creative cannot
  # capture the whole ad's spend.
  def resolve_asset(creative)
    feed = creative["asset_feed_spec"] || {}
    videos = Array(feed["videos"]).map { |v| v["video_id"] }.compact.uniq
    images = Array(feed["images"]).map { |i| i["hash"] }.compact.uniq

    return { asset_type: nil, asset_id: nil, multi_asset: true } if videos.size + images.size > 1

    story = creative["object_story_spec"] || {}

    video_id = creative["video_id"].presence ||
               story.dig("video_data", "video_id").presence ||
               videos.first
    return { asset_type: "video", asset_id: video_id, multi_asset: false } if video_id.present?

    image_hash = creative["image_hash"].presence ||
                 images.first ||
                 story.dig("link_data", "image_hash").presence
    return { asset_type: "image", asset_id: image_hash, multi_asset: false } if image_hash.present?

    { asset_type: nil, asset_id: nil, multi_asset: false }
  end

  def find_or_create_creative(resolved, fallback_name)
    return nil if resolved[:asset_id].blank?

    creative = @ad_account.ad_creatives.find_or_initialize_by(
      asset_type: resolved[:asset_type], asset_id: resolved[:asset_id]
    )
    creative.name ||= fallback_name
    creative.save!
    creative
  end

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

  # Video insight fields are list<AdsActionStats>, not scalars (spec §2.3).
  # Sum every entry rather than picking action_type == "video_view", so a new
  # action_type from Meta cannot silently drop counts.
  def extract_video_metric(list)
    return 0 if list.blank?

    list.sum { |entry| entry["value"].to_i }
  end
end
