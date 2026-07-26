require "rails_helper"

RSpec.describe MetaAdsService do
  let(:ad_account) { create(:ad_account, access_token: "test-token", token_expires_at: 60.days.from_now) }
  let(:service) { described_class.new(ad_account) }

  describe "#sync_date_range" do
    it "creates daily metrics from insights" do
      graph = instance_double(Koala::Facebook::API)
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)

      allow(graph).to receive(:get_connections).and_return([
        {
          "date_start" => "2026-03-27",
          "spend" => "150.50",
          "impressions" => "5000",
          "clicks" => "200",
          "actions" => [
            { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "10" }
          ],
          "action_values" => [
            { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "750.00" }
          ]
        }
      ])

      expect {
        service.sync_date_range(Date.new(2026, 3, 27), Date.new(2026, 3, 27))
      }.to change(AdDailyMetric, :count).by(1)

      metric = ad_account.ad_daily_metrics.find_by(date: "2026-03-27")
      expect(metric.spend).to eq(150.50)
      expect(metric.impressions).to eq(5000)
      expect(metric.clicks).to eq(200)
      expect(metric.conversions).to eq(10)
      expect(metric.conversion_value).to eq(750.00)
    end

    it "updates existing metrics" do
      create(:ad_daily_metric, ad_account: ad_account, date: "2026-03-27", spend: 100)

      graph = instance_double(Koala::Facebook::API)
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)

      allow(graph).to receive(:get_connections).and_return([
        {
          "date_start" => "2026-03-27",
          "spend" => "200.00",
          "impressions" => "6000",
          "clicks" => "250",
          "actions" => nil,
          "action_values" => nil
        }
      ])

      expect {
        service.sync_date_range(Date.new(2026, 3, 27), Date.new(2026, 3, 27))
      }.not_to change(AdDailyMetric, :count)

      metric = ad_account.ad_daily_metrics.find_by(date: "2026-03-27")
      expect(metric.spend).to eq(200.00)
      expect(metric.conversions).to eq(0)
    end

    it "handles missing actions gracefully" do
      graph = instance_double(Koala::Facebook::API)
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)

      allow(graph).to receive(:get_connections).and_return([
        {
          "date_start" => "2026-03-27",
          "spend" => "50.00",
          "impressions" => "1000",
          "clicks" => "30",
          "actions" => nil,
          "action_values" => nil
        }
      ])

      service.sync_date_range(Date.new(2026, 3, 27), Date.new(2026, 3, 27))
      metric = ad_account.ad_daily_metrics.find_by(date: "2026-03-27")
      expect(metric.conversions).to eq(0)
      expect(metric.conversion_value).to eq(0)
    end
  end

  describe "#sync_campaigns" do
    let(:graph) { instance_double(Koala::Facebook::API) }

    before do
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)
    end

    it "creates campaigns from Meta API data" do
      allow(graph).to receive(:get_connections).and_return([
        {
          "id" => "camp_001",
          "name" => "Summer Sale",
          "effective_status" => "ACTIVE",
          "daily_budget" => "5000"
        },
        {
          "id" => "camp_002",
          "name" => "Winter Promo",
          "effective_status" => "PAUSED",
          "daily_budget" => "3000"
        }
      ])

      expect {
        service.sync_campaigns
      }.to change(AdCampaign, :count).by(2)

      campaign = ad_account.ad_campaigns.find_by(campaign_id: "camp_001")
      expect(campaign.campaign_name).to eq("Summer Sale")
      expect(campaign.status).to eq("active")
      expect(campaign.daily_budget).to eq(50.0)

      paused = ad_account.ad_campaigns.find_by(campaign_id: "camp_002")
      expect(paused.status).to eq("paused")
      expect(paused.daily_budget).to eq(30.0)
    end

    it "updates existing campaigns" do
      create(:ad_campaign, ad_account: ad_account, campaign_id: "camp_001", campaign_name: "Old Name", status: "active")

      allow(graph).to receive(:get_connections).and_return([
        {
          "id" => "camp_001",
          "name" => "New Name",
          "effective_status" => "PAUSED",
          "daily_budget" => "10000"
        }
      ])

      expect {
        service.sync_campaigns
      }.not_to change(AdCampaign, :count)

      campaign = ad_account.ad_campaigns.find_by(campaign_id: "camp_001")
      expect(campaign.campaign_name).to eq("New Name")
      expect(campaign.status).to eq("paused")
    end

    it "maps DELETED and ARCHIVED statuses" do
      allow(graph).to receive(:get_connections).and_return([
        { "id" => "camp_d", "name" => "Deleted", "effective_status" => "DELETED", "daily_budget" => "0" },
        { "id" => "camp_a", "name" => "Archived", "effective_status" => "ARCHIVED", "daily_budget" => "0" }
      ])

      service.sync_campaigns

      expect(ad_account.ad_campaigns.find_by(campaign_id: "camp_d").status).to eq("deleted")
      expect(ad_account.ad_campaigns.find_by(campaign_id: "camp_a").status).to eq("deleted")
    end
  end

  describe "#sync_campaign_insights" do
    let(:graph) { instance_double(Koala::Facebook::API) }
    let!(:campaign) { create(:ad_campaign, ad_account: ad_account, campaign_id: "camp_001") }

    before do
      allow(Koala::Facebook::API).to receive(:new).and_return(graph)
      # stub campaigns fetch (used in sync_campaigns, not here directly)
      allow(graph).to receive(:get_connections).with(
        "camp_001", "insights", anything
      ).and_return([
        {
          "date_start" => "2026-03-27",
          "spend" => "100.50",
          "impressions" => "5000",
          "clicks" => "200",
          "actions" => [
            { "action_type" => "offsite_conversion.fb_pixel_add_to_cart", "value" => "30" },
            { "action_type" => "offsite_conversion.fb_pixel_initiate_checkout", "value" => "15" },
            { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "8" }
          ],
          "action_values" => [
            { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "600.00" }
          ]
        }
      ])
    end

    it "creates daily metrics for campaigns" do
      expect {
        service.sync_campaign_insights(Date.new(2026, 3, 27), Date.new(2026, 3, 27))
      }.to change(AdCampaignDailyMetric, :count).by(1)

      metric = campaign.ad_campaign_daily_metrics.find_by(date: "2026-03-27")
      expect(metric.impressions).to eq(5000)
      expect(metric.clicks).to eq(200)
      expect(metric.add_to_cart).to eq(30)
      expect(metric.checkout_initiated).to eq(15)
      expect(metric.purchases).to eq(8)
      expect(metric.spend).to eq(100.50)
      expect(metric.conversion_value).to eq(600.00)
    end

    it "updates existing campaign metrics" do
      create(:ad_campaign_daily_metric, ad_campaign: campaign, date: "2026-03-27", spend: 50)

      expect {
        service.sync_campaign_insights(Date.new(2026, 3, 27), Date.new(2026, 3, 27))
      }.not_to change(AdCampaignDailyMetric, :count)

      metric = campaign.ad_campaign_daily_metrics.find_by(date: "2026-03-27")
      expect(metric.spend).to eq(100.50)
    end

    it "handles API errors per campaign gracefully" do
      allow(graph).to receive(:get_connections).with(
        "camp_001", "insights", anything
      ).and_raise(Koala::Facebook::ClientError.new(400, "Rate limited"))

      expect { service.sync_campaign_insights(Date.new(2026, 3, 27), Date.new(2026, 3, 27)) }.not_to raise_error
    end
  end

  describe "#sync_ad_units" do
    let(:graph) { instance_double(Koala::Facebook::API) }

    before { allow(Koala::Facebook::API).to receive(:new).and_return(graph) }

    def stub_ads(*ads)
      allow(graph).to receive(:get_connections).and_return(ads)
    end

    def ad_payload(id:, creative:)
      {
        "id" => id, "name" => "Ad #{id}", "adset_id" => "adset_1",
        "campaign_id" => "camp_1", "effective_status" => "ACTIVE",
        "creative" => creative
      }
    end

    it "resolves creative.video_id (branch 2)" do
      stub_ads(ad_payload(id: "a1", creative: { "id" => "c1", "video_id" => "v9" }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a1")
      expect(unit.multi_asset).to be(false)
      expect(unit.ad_creative.asset_type).to eq("video")
      expect(unit.ad_creative.asset_id).to eq("v9")
    end

    it "resolves object_story_spec video_data (branch 3)" do
      stub_ads(ad_payload(id: "a2", creative: {
        "id" => "c2", "object_story_spec" => { "video_data" => { "video_id" => "v8" } }
      }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a2").ad_creative.asset_id).to eq("v8")
    end

    it "resolves a single video inside asset_feed_spec (branch 4)" do
      stub_ads(ad_payload(id: "a3", creative: {
        "id" => "c3", "asset_feed_spec" => { "videos" => [ { "video_id" => "v7" } ] }
      }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a3")
      expect(unit.multi_asset).to be(false)
      expect(unit.ad_creative.asset_id).to eq("v7")
    end

    it "resolves creative.image_hash (branch 5)" do
      stub_ads(ad_payload(id: "a4", creative: { "id" => "c4", "image_hash" => "h1" }))

      service.sync_ad_units

      creative = AdUnit.find_by(ad_id: "a4").ad_creative
      expect(creative.asset_type).to eq("image")
      expect(creative.asset_id).to eq("h1")
    end

    it "resolves a single image inside asset_feed_spec (branch 6)" do
      stub_ads(ad_payload(id: "a5", creative: {
        "id" => "c5", "asset_feed_spec" => { "images" => [ { "hash" => "h2" } ] }
      }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a5").ad_creative.asset_id).to eq("h2")
    end

    it "resolves link_data image_hash (branch 7)" do
      stub_ads(ad_payload(id: "a6", creative: {
        "id" => "c6", "object_story_spec" => { "link_data" => { "image_hash" => "h3" } }
      }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a6").ad_creative.asset_id).to eq("h3")
    end

    it "marks multiple distinct media as multi_asset (branch 1)" do
      stub_ads(ad_payload(id: "a7", creative: {
        "id" => "c7",
        "asset_feed_spec" => { "videos" => [ { "video_id" => "v1" }, { "video_id" => "v2" } ] }
      }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a7")
      expect(unit.multi_asset).to be(true)
      expect(unit.ad_creative_id).to be_nil
    end

    it "treats mixed video and image as multi_asset" do
      stub_ads(ad_payload(id: "a8", creative: {
        "id" => "c8",
        "asset_feed_spec" => { "videos" => [ { "video_id" => "v1" } ], "images" => [ { "hash" => "h1" } ] }
      }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a8").multi_asset).to be(true)
    end

    it "prefers the multi_asset branch over a residual top-level video_id" do
      stub_ads(ad_payload(id: "a9", creative: {
        "id" => "c9", "video_id" => "residual",
        "asset_feed_spec" => { "videos" => [ { "video_id" => "v1" }, { "video_id" => "v2" } ] }
      }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a9")
      expect(unit.multi_asset).to be(true)
      expect(AdCreative.find_by(asset_id: "residual")).to be_nil
    end

    it "counts duplicate media ids as one distinct asset" do
      stub_ads(ad_payload(id: "a10", creative: {
        "id" => "c10",
        "asset_feed_spec" => { "videos" => [ { "video_id" => "v1" }, { "video_id" => "v1" } ] }
      }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a10")
      expect(unit.multi_asset).to be(false)
      expect(unit.ad_creative.asset_id).to eq("v1")
    end

    it "attributes a single media asset that also carries customization rules" do
      stub_ads(ad_payload(id: "a11", creative: {
        "id" => "c11",
        "asset_feed_spec" => {
          "videos" => [ { "video_id" => "v1" } ],
          "asset_customization_rules" => [ { "customization_spec" => { "publisher_platforms" => [ "facebook" ] } } ]
        }
      }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a11")
      expect(unit.multi_asset).to be(false)
      expect(unit.ad_creative.asset_id).to eq("v1")
    end

    it "leaves an unknown creative shape unattributed without marking multi_asset (branch 8)" do
      stub_ads(ad_payload(id: "a12", creative: { "id" => "c12" }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a12")
      expect(unit.ad_creative_id).to be_nil
      expect(unit.multi_asset).to be(false)
    end

    it "resolves an existing-post ad via effective_object_story_id as asset_type post" do
      stub_ads(ad_payload(id: "a17", creative: {
        "id" => "c17", "effective_object_story_id" => "110994158524036_814351261565235"
      }))

      service.sync_ad_units

      creative = AdUnit.find_by(ad_id: "a17").ad_creative
      expect(creative.asset_type).to eq("post")
      expect(creative.asset_id).to eq("110994158524036_814351261565235")
    end

    it "falls back to object_story_id when effective_object_story_id is absent" do
      stub_ads(ad_payload(id: "a18", creative: {
        "id" => "c18", "object_story_id" => "110994158524036_999"
      }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a18").ad_creative.asset_id).to eq("110994158524036_999")
    end

    it "resolves as video, not post, when a creative carries both a real video_id and an object_story_id" do
      stub_ads(ad_payload(id: "a19", creative: {
        "id" => "c19", "video_id" => "v20",
        "object_story_id" => "110994158524036_111", "effective_object_story_id" => "110994158524036_111"
      }))

      service.sync_ad_units

      creative = AdUnit.find_by(ad_id: "a19").ad_creative
      expect(creative.asset_type).to eq("video")
      expect(creative.asset_id).to eq("v20")
    end

    it "populates thumbnail_url from the ads payload's creative.thumbnail_url" do
      stub_ads(ad_payload(id: "a20", creative: {
        "id" => "c20", "video_id" => "v21", "thumbnail_url" => "https://x/from-ad.jpg"
      }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a20").ad_creative.thumbnail_url).to eq("https://x/from-ad.jpg")
    end

    it "does not overwrite an existing non-blank thumbnail_url on resync" do
      existing = create(:ad_creative, ad_account: ad_account, asset_type: "video",
        asset_id: "v22", thumbnail_url: "https://x/better.jpg")
      stub_ads(ad_payload(id: "a21", creative: {
        "id" => "c21", "video_id" => "v22", "thumbnail_url" => "https://x/from-ad.jpg"
      }))

      service.sync_ad_units

      expect(existing.reload.thumbnail_url).to eq("https://x/better.jpg")
    end

    it "links the ad unit to an existing campaign" do
      campaign = create(:ad_campaign, ad_account: ad_account, campaign_id: "camp_1")
      stub_ads(ad_payload(id: "a13", creative: { "id" => "c13", "video_id" => "v1" }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a13").ad_campaign).to eq(campaign)
    end

    it "reuses one creative across several ads" do
      stub_ads(
        ad_payload(id: "a14", creative: { "id" => "c14", "video_id" => "shared" }),
        ad_payload(id: "a15", creative: { "id" => "c15", "video_id" => "shared" })
      )

      expect { service.sync_ad_units }.to change(AdCreative, :count).by(1)
      expect(AdUnit.count).to eq(2)
    end

    it "is idempotent across repeated syncs" do
      stub_ads(ad_payload(id: "a16", creative: { "id" => "c16", "video_id" => "v1" }))

      service.sync_ad_units
      expect { service.sync_ad_units }.not_to change(AdUnit, :count)
    end
  end

  describe "#refresh_token_if_needed!" do
    it "refreshes token when expiring soon" do
      ad_account.update!(token_expires_at: 3.days.from_now)

      oauth = instance_double(Koala::Facebook::OAuth)
      allow(Koala::Facebook::OAuth).to receive(:new).and_return(oauth)
      allow(oauth).to receive(:exchange_access_token_info).and_return({
        "access_token" => "new-long-token",
        "expires_in" => 5_184_000
      })

      service.refresh_token_if_needed!

      ad_account.reload
      expect(ad_account.access_token).to eq("new-long-token")
      expect(ad_account.token_expires_at).to be > 50.days.from_now
    end

    it "does not refresh when token is not expiring soon" do
      ad_account.update!(token_expires_at: 30.days.from_now)

      expect(Koala::Facebook::OAuth).not_to receive(:new)
      service.refresh_token_if_needed!
    end

    it "does not refresh when token_expires_at is nil" do
      ad_account.update!(token_expires_at: nil)

      expect(Koala::Facebook::OAuth).not_to receive(:new)
      service.refresh_token_if_needed!
    end
  end

  describe "#fetch_ad_insights" do
    let(:graph) { instance_double(Koala::Facebook::API) }

    before { allow(Koala::Facebook::API).to receive(:new).and_return(graph) }

    def insight_row(overrides = {})
      {
        "ad_id" => "a1", "date_start" => "2026-07-01",
        "spend" => "12.50", "impressions" => "1000", "clicks" => "40",
        "inline_link_clicks" => "30",
        "video_p25_watched_actions" => [ { "action_type" => "video_view", "value" => "250" } ],
        "video_p50_watched_actions" => [ { "action_type" => "video_view", "value" => "150" } ],
        "video_p75_watched_actions" => [ { "action_type" => "video_view", "value" => "90" } ],
        "video_p95_watched_actions" => [ { "action_type" => "video_view", "value" => "50" } ],
        "video_p100_watched_actions" => [ { "action_type" => "video_view", "value" => "40" } ],
        "actions" => [
          { "action_type" => "offsite_conversion.fb_pixel_add_to_cart", "value" => "8" },
          { "action_type" => "offsite_conversion.fb_pixel_initiate_checkout", "value" => "4" },
          { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "2" }
        ],
        "action_values" => [
          { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "88.00" }
        ]
      }.merge(overrides)
    end

    it "parses list-valued video fields into integers" do
      allow(graph).to receive(:get_connections).and_return([ insight_row ])

      row = service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1)).first

      expect(row[:video_p50_watched]).to eq(150)
      expect(row[:video_p75_watched]).to eq(90)
    end

    # Meta does not emit video_continuous_2_sec_watched_actions for this
    # account at all -- the real "3-Second Video Views" metric lives inside
    # `actions` as action_type "video_view" (confirmed against production).
    # Extracted via the same extract_action_count helper the conversion
    # fields below already use, not the list-summing video helper.
    it "extracts the 3-second play count from the video_view action" do
      allow(graph).to receive(:get_connections).and_return([
        insight_row("actions" => insight_row["actions"] + [
          { "action_type" => "video_view", "value" => "220" }
        ])
      ])

      row = service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1)).first

      expect(row[:video_3_sec_watched]).to eq(220)
    end

    it "returns zero for video_3_sec_watched when actions has no video_view entry" do
      allow(graph).to receive(:get_connections).and_return([ insight_row ])

      row = service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1)).first

      expect(row[:video_3_sec_watched]).to eq(0)
    end

    it "sums every entry in a video action list" do
      allow(graph).to receive(:get_connections).and_return([
        insight_row("video_p50_watched_actions" => [
          { "action_type" => "video_view", "value" => "100" },
          { "action_type" => "something_new", "value" => "20" }
        ])
      ])

      row = service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1)).first

      expect(row[:video_p50_watched]).to eq(120)
    end

    it "returns zero for absent video fields (image ads)" do
      allow(graph).to receive(:get_connections).and_return([
        insight_row.except(
          "video_p25_watched_actions",
          "video_p50_watched_actions", "video_p75_watched_actions",
          "video_p95_watched_actions", "video_p100_watched_actions"
        )
      ])

      row = service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1)).first

      expect(row[:video_p50_watched]).to eq(0)
    end

    it "parses conversions with the full offsite_conversion action types" do
      allow(graph).to receive(:get_connections).and_return([ insight_row ])

      row = service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1)).first

      expect(row[:add_to_cart]).to eq(8)
      expect(row[:checkout_initiated]).to eq(4)
      expect(row[:purchases]).to eq(2)
      expect(row[:conversion_value]).to eq(88.00)
    end

    it "requests account attribution settings and ad-level daily granularity" do
      expect(graph).to receive(:get_connections) do |_node, edge, **params|
        expect(edge).to eq("insights")
        expect(params[:level]).to eq("ad")
        expect(params[:time_increment]).to eq(1)
        expect(params[:use_account_attribution_setting]).to be(true)
        expect(params[:limit]).to eq(500)
        expect(params[:time_range]).to eq({ since: "2026-07-01", until: "2026-07-03" })
        []
      end

      service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 3))
    end

    it "writes nothing to the database" do
      allow(graph).to receive(:get_connections).and_return([ insight_row ])

      expect {
        service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1))
      }.not_to change(AdUnitDailyMetric, :count)
    end
  end

  describe "#sync_creative_assets" do
    let(:graph) { instance_double(Koala::Facebook::API) }

    before { allow(Koala::Facebook::API).to receive(:new).and_return(graph) }

    it "backfills name, duration and thumbnail for a video creative" do
      creative = create(:ad_creative, ad_account: ad_account, asset_type: "video",
        asset_id: "v1", thumbnail_url: nil, name: nil, duration_seconds: nil)
      allow(graph).to receive(:get_object).with("v1", fields: "title,length,thumbnails,picture")
        .and_return({ "title" => "Hook A", "length" => "27.5", "picture" => "https://x/t.jpg" })

      service.sync_creative_assets

      creative.reload
      expect(creative.name).to eq("Hook A")
      expect(creative.duration_seconds).to eq(27)
      expect(creative.thumbnail_url).to eq("https://x/t.jpg")
    end

    it "skips creatives that already have a thumbnail" do
      create(:ad_creative, ad_account: ad_account, asset_type: "video", thumbnail_url: "https://x/have.jpg")
      expect(graph).not_to receive(:get_object)

      service.sync_creative_assets
    end

    it "skips image creatives" do
      create(:ad_creative, ad_account: ad_account, asset_type: "image", asset_id: "h1", thumbnail_url: nil)
      expect(graph).not_to receive(:get_object)

      service.sync_creative_assets
    end

    it "keeps an existing name when the video has no title" do
      creative = create(:ad_creative, ad_account: ad_account, asset_type: "video",
        asset_id: "v2", name: "Existing", thumbnail_url: nil)
      allow(graph).to receive(:get_object).and_return({ "picture" => "https://x/t.jpg" })

      service.sync_creative_assets

      expect(creative.reload.name).to eq("Existing")
    end

    it "logs and continues when one video lookup fails" do
      create(:ad_creative, ad_account: ad_account, asset_type: "video", asset_id: "v3", thumbnail_url: nil)
      create(:ad_creative, ad_account: ad_account, asset_type: "video", asset_id: "v4", thumbnail_url: nil)
      call = 0
      allow(graph).to receive(:get_object) do
        call += 1
        raise Koala::Facebook::ClientError.new(400, "gone") if call == 1
        { "picture" => "https://x/ok.jpg" }
      end

      expect { service.sync_creative_assets }.not_to raise_error
      expect(call).to eq(2)
    end

    it "increments thumbnail_fetch_attempts on failure" do
      creative = create(:ad_creative, ad_account: ad_account, asset_type: "video",
        asset_id: "v5", thumbnail_url: nil, thumbnail_fetch_attempts: 0)
      allow(graph).to receive(:get_object).and_raise(Koala::Facebook::ClientError.new(400, "OAuthException code 10"))

      service.sync_creative_assets

      expect(creative.reload.thumbnail_fetch_attempts).to eq(1)
    end

    it "resets thumbnail_fetch_attempts to zero on success" do
      creative = create(:ad_creative, ad_account: ad_account, asset_type: "video",
        asset_id: "v6", thumbnail_url: nil, thumbnail_fetch_attempts: 2)
      allow(graph).to receive(:get_object).and_return({ "picture" => "https://x/ok.jpg" })

      service.sync_creative_assets

      expect(creative.reload.thumbnail_fetch_attempts).to eq(0)
    end

    it "skips a creative that has exceeded the retry cap" do
      create(:ad_creative, ad_account: ad_account, asset_type: "video",
        asset_id: "v7", thumbnail_url: nil,
        thumbnail_fetch_attempts: MetaAdsService::THUMBNAIL_FETCH_ATTEMPT_CAP)
      expect(graph).not_to receive(:get_object)

      service.sync_creative_assets
    end

    it "still retries a creative one attempt below the cap" do
      creative = create(:ad_creative, ad_account: ad_account, asset_type: "video",
        asset_id: "v8", thumbnail_url: nil,
        thumbnail_fetch_attempts: MetaAdsService::THUMBNAIL_FETCH_ATTEMPT_CAP - 1)
      allow(graph).to receive(:get_object).and_raise(Koala::Facebook::ClientError.new(400, "gone"))

      service.sync_creative_assets

      expect(creative.reload.thumbnail_fetch_attempts).to eq(MetaAdsService::THUMBNAIL_FETCH_ATTEMPT_CAP)
    end
  end
end
