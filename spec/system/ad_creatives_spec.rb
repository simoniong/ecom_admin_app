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
    click_link "Ad Creatives"
    expect(page).to have_text("No ad creatives found")
  end

  it "shows creatives with engagement metrics" do
    creative_with_metrics(
      name: "Toy Duck Demo v1", first_spend_date: Date.current - 10,
      impressions: 10_000, inline_link_clicks: 300,
      video_continuous_2_sec_watched: 3_700, video_p50_watched: 1_200, video_p75_watched: 700
    )

    sign_in_as(user)
    click_link "Ad Creatives"

    expect(page).to have_text("Toy Duck Demo v1")
    expect(page).to have_text("Meta Ads")
    expect(page).to have_text("37.0%")
    expect(page).to have_text("12.0%")
    expect(page).to have_text("3.0%")
  end

  it "shows a dash for completion columns on an image creative" do
    creative = create(:ad_creative, ad_account: ad_account, asset_type: "image",
      asset_id: "hash1", name: "Static Banner", first_spend_date: Date.current - 10)
    unit = create(:ad_unit, ad_account: ad_account, ad_creative: creative)
    create(:ad_unit_daily_metric, ad_unit: unit, date: Date.current,
      impressions: 5_000, video_continuous_2_sec_watched: 0,
      video_p50_watched: 0, video_p75_watched: 0)

    sign_in_as(user)
    click_link "Ad Creatives"

    expect(page).to have_text("Static Banner")
    within("tr", text: "Static Banner") { expect(page).to have_text("—") }
  end

  it "marks a creative whose first spend predates the synced range" do
    creative_with_metrics(name: "Old Hook", first_spend_date: Date.current - 89, spend: 40)

    sign_in_as(user)
    click_link "Ad Creatives"

    within("tr", text: "Old Hook") { expect(page).to have_css("[data-anchor-state='truncated']") }
  end

  it "sorts by a chosen column" do
    creative_with_metrics(name: "Low Spender", first_spend_date: Date.current - 10, spend: 10)
    creative_with_metrics(name: "High Spender", first_spend_date: Date.current - 10, spend: 900)

    sign_in_as(user)
    click_link "Ad Creatives"
    click_link "Lifetime Spend"

    rows = page.all("tbody tr").map(&:text)
    expect(rows.first).to include("High Spender")
  end

  it "filters by date range" do
    creative_with_metrics(name: "In Range", first_spend_date: Date.current - 10, impressions: 4_242)

    sign_in_as(user)
    click_link "Ad Creatives"
    fill_in "from_date", with: (Date.current - 1).to_s
    fill_in "to_date", with: Date.current.to_s
    click_button "Filter"

    # 3,000 / 4,242 video_continuous_2_sec_watched/impressions (factory defaults) => two_sec_rate.
    # Asserting on the computed rate (rather than the raw impressions count, which the table
    # never displays as its own figure) proves the in-range metric was actually aggregated.
    expect(page).to have_text("70.7%")
  end
end
