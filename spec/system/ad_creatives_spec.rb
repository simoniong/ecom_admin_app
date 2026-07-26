require "rails_helper"

RSpec.describe "Ad Creatives", type: :system do
  let!(:user) { create(:user) }
  let!(:store) { create(:shopify_store, user: user) }
  let!(:ad_account) do
    create(:ad_account, user: user, shopify_store: store, account_name: "Meta Ads",
      creative_synced_from_date: Date.current - 89, creative_synced_through_date: Date.current)
  end

  def creative_with_metrics(name:, first_spend_date:, **metric_attrs)
    creative = create(:ad_creative, ad_account: ad_account, name: name, first_spend_date: first_spend_date)
    unit = create(:ad_unit, ad_account: ad_account, ad_creative: creative)
    create(:ad_unit_daily_metric, { ad_unit: unit, date: Date.current }.merge(metric_attrs))
    creative
  end

  it "shows the empty state when there are no creatives" do
    sign_in_as(user)
    navigate_to_settings_item(I18n.t("nav.ad_creatives"), group: I18n.t("nav.ads"))
    expect(page).to have_text("No ad creatives found")
  end

  it "shows creatives with engagement metrics" do
    creative_with_metrics(
      name: "Toy Duck Demo v1", first_spend_date: Date.current - 10,
      spend: 300, impressions: 10_000, inline_link_clicks: 300, clicks: 600,
      video_3_sec_watched: 3_700, video_p50_watched: 1_200, video_p75_watched: 700
    )

    sign_in_as(user)
    navigate_to_settings_item(I18n.t("nav.ad_creatives"), group: I18n.t("nav.ads"))

    expect(page).to have_text("Toy Duck Demo v1")
    expect(page).to have_text("Meta Ads")
    expect(page).to have_text("37.0%")
    expect(page).to have_text("12.0%")
    expect(page).to have_text("3.0%")
    # CPC (link click) = 300/300 = $1.00, CPC (all clicks) = 300/600 = $0.50, CPM = 300/10,000*1,000 = $30.00.
    within("tr", text: "Toy Duck Demo v1") do
      expect(page).to have_text("$1.00")
      expect(page).to have_text("$0.50")
      expect(page).to have_text("$30.00")
    end
  end

  it "shows a dash for completion columns on an image creative" do
    creative = create(:ad_creative, ad_account: ad_account, asset_type: "image",
      asset_id: "hash1", name: "Static Banner", first_spend_date: Date.current - 10)
    unit = create(:ad_unit, ad_account: ad_account, ad_creative: creative)
    create(:ad_unit_daily_metric, ad_unit: unit, date: Date.current,
      impressions: 5_000, video_3_sec_watched: 0,
      video_p50_watched: 0, video_p75_watched: 0)

    sign_in_as(user)
    navigate_to_settings_item(I18n.t("nav.ad_creatives"), group: I18n.t("nav.ads"))

    expect(page).to have_text("Static Banner")
    within("tr", text: "Static Banner") { expect(page).to have_text("—") }
  end

  it "marks a creative whose first spend predates the synced range" do
    creative_with_metrics(name: "Old Hook", first_spend_date: Date.current - 89, spend: 40)

    sign_in_as(user)
    navigate_to_settings_item(I18n.t("nav.ad_creatives"), group: I18n.t("nav.ads"))

    within("tr", text: "Old Hook") { expect(page).to have_css("[data-anchor-state='truncated']") }
  end

  # Lifetime is still an accurate sum over the synced interval for a
  # truncated creative (merely incomplete), unlike D1/D3/D5, which are
  # anchored on a false first day and therefore actually wrong -- so only
  # the lifetime columns should show their number alongside the ⚠ marker.
  it "shows the lifetime figure alongside the marker, but hides D1/D3/D5, for a truncated creative" do
    creative_with_metrics(name: "Old Hook", first_spend_date: Date.current - 89, spend: 40)

    sign_in_as(user)
    navigate_to_settings_item(I18n.t("nav.ad_creatives"), group: I18n.t("nav.ads"))

    within("tr", text: "Old Hook") do
      cells = all("td[data-anchor-state='truncated']")
      expect(cells.size).to eq(6)

      d1_spend, d1_purchases, d3_roas, d5_roas, lifetime_spend, lifetime_roas = cells

      expect(d1_spend.text.strip).to eq("⚠")
      expect(d1_purchases.text.strip).to eq("⚠")
      expect(d3_roas.text.strip).to eq("⚠")
      expect(d5_roas.text.strip).to eq("⚠")

      expect(lifetime_spend.text).to include("⚠")
      expect(lifetime_spend.text).to include("$40.00")
      expect(lifetime_roas.text).to include("⚠")
    end
  end

  it "sorts by a chosen column" do
    creative_with_metrics(name: "Low Spender", first_spend_date: Date.current - 10, spend: 10)
    creative_with_metrics(name: "High Spender", first_spend_date: Date.current - 10, spend: 900)

    sign_in_as(user)
    navigate_to_settings_item(I18n.t("nav.ad_creatives"), group: I18n.t("nav.ads"))
    click_link "Lifetime Spend"

    # `page.all(...).map(&:text)` takes an unsynchronized snapshot of the DOM — it can grab
    # element handles from the pre-navigation page that go stale mid-map after the sort link's
    # click triggers a fresh render. Asserting via `have_css` on the first row instead gives a
    # retrying matcher that self-synchronizes against the live DOM.
    #
    # The default page load is already sorted by lifetime_spend desc, so High Spender is first
    # BEFORE the click too — asserting "High Spender" here would pass against the stale
    # pre-navigation DOM the instant have_css's first poll runs, never actually waiting for the
    # click's navigation, and would stay green even with sorting completely broken. The
    # "Lifetime Spend" header link toggles direction on click (desc -> asc, since the page is
    # already sorted desc by default), so following it flips the order and Low Spender becomes
    # first. Asserting "Low Spender" is therefore both the value the click genuinely produces
    # and the opposite of the pre-navigation DOM, so the matcher cannot succeed until the sorted
    # page has actually rendered — do not "fix" this back to "High Spender".
    expect(page).to have_css("tbody tr:first-child", text: "Low Spender")
  end

  # percentage/ratio/per_mille return 0 on a zero denominator (that struct
  # contract is unchanged -- see spec/models/ad_creative_spec.rb), but a zero
  # denominator means "no data in the selected range", not a real 0.0%/$0.00.
  # A creative with no impressions in range must not drown the table in a
  # wall of misleading zeros.
  it "shows a dash rather than 0.0%/$0.00 for range-scoped columns when the range has no impressions" do
    creative_with_metrics(
      name: "Idle Creative", first_spend_date: nil,
      impressions: 0, inline_link_clicks: 0, clicks: 0, spend: 0,
      video_3_sec_watched: 0, video_p50_watched: 0, video_p75_watched: 0
    )

    sign_in_as(user)
    navigate_to_settings_item(I18n.t("nav.ad_creatives"), group: I18n.t("nav.ads"))

    within("tr", text: "Idle Creative") do
      expect(page).not_to have_text("0.0%")
      expect(page).not_to have_text("$0.00")
    end
  end

  it "filters by date range" do
    creative_with_metrics(name: "In Range", first_spend_date: Date.current - 10, impressions: 4_242)

    sign_in_as(user)
    navigate_to_settings_item(I18n.t("nav.ad_creatives"), group: I18n.t("nav.ads"))
    fill_in "from_date", with: (Date.current - 1).to_s
    fill_in "to_date", with: Date.current.to_s
    click_button "Filter"

    # 3,000 / 4,242 video_3_sec_watched/impressions (factory defaults) => three_sec_rate.
    # Asserting on the computed rate (rather than the raw impressions count, which the table
    # never displays as its own figure) proves the in-range metric was actually aggregated.
    expect(page).to have_text("70.7%")
  end
end
