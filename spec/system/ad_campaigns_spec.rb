require "rails_helper"

RSpec.describe "Ad Campaigns", type: :system do
  let!(:user) { create(:user) }
  let!(:store) { create(:shopify_store, user: user) }
  let!(:ad_account) { create(:ad_account, user: user, shopify_store: store, account_name: "Meta Ads") }

  it "shows empty state when no campaigns" do
    sign_in_as(user)
    click_link "Ad Campaigns"
    expect(page).to have_text("No ad campaigns found")
  end

  it "shows campaign list with metrics" do
    campaign = create(:ad_campaign, ad_account: ad_account, campaign_name: "Black Friday", status: "active")
    create(:ad_campaign_daily_metric, ad_campaign: campaign, date: Date.current,
      impressions: 10_000, clicks: 500, add_to_cart: 80, checkout_initiated: 40,
      purchases: 20, spend: 250, conversion_value: 1000)

    sign_in_as(user)
    click_link "Ad Campaigns"

    expect(page).to have_text("Black Friday")
    expect(page).to have_text("Meta Ads")
    expect(page).to have_text("Active")
    expect(page).to have_text("10,000")
    expect(page).to have_text("500")
  end

  it "filters by date range" do
    campaign = create(:ad_campaign, ad_account: ad_account, campaign_name: "Test Campaign")
    create(:ad_campaign_daily_metric, ad_campaign: campaign, date: Date.current, impressions: 5000)
    create(:ad_campaign_daily_metric, ad_campaign: campaign, date: 30.days.ago.to_date, impressions: 9999)

    sign_in_as(user)
    visit ad_campaigns_path(from_date: 3.days.ago.to_date, to_date: Date.current)

    expect(page).to have_text("5,000")
    expect(page).not_to have_text("9,999")
  end

  context "with multiple stores" do
    let!(:store2) { create(:shopify_store, user: user) }

    it "shows store selector dropdown" do
      sign_in_as(user)
      click_link "Ad Campaigns"
      expect(page).to have_select("shopify_store_id")
    end
  end

  context "with multiple ad accounts" do
    let!(:account2) { create(:ad_account, user: user, shopify_store: store, account_name: "Google Ads") }

    it "shows ad account selector" do
      create(:ad_campaign, ad_account: ad_account, campaign_name: "Meta Campaign")
      create(:ad_campaign, ad_account: account2, campaign_name: "Google Campaign")

      sign_in_as(user)
      click_link "Ad Campaigns"

      expect(page).to have_select("ad_account_id")
      expect(page).to have_text("Meta Campaign")
      expect(page).to have_text("Google Campaign")
    end
  end

  it "shows date range quick pick buttons" do
    sign_in_as(user)
    click_link "Ad Campaigns"

    expect(page).to have_button("Today")
    expect(page).to have_button("Yesterday")
    expect(page).to have_button("Last 7 Days")
    expect(page).to have_button("This Month")
    expect(page).to have_button("Maximum")
  end

  it "shows column toggle popover with checkboxes" do
    create(:ad_campaign, ad_account: ad_account, campaign_name: "Test Camp")

    sign_in_as(user)
    click_link "Ad Campaigns"

    # Open column toggle modal (first match is the column icon button)
    find("[data-action*='ad-column-toggle#toggle']", match: :first).click

    # Popover shows column checkboxes and save-as-new button
    expect(page).to have_css("[data-ad-column-toggle-target='dropdown']", visible: true)
    expect(page).to have_css("[data-ad-column-toggle-target='checkbox']", minimum: 1)
    expect(page).to have_button(I18n.t("campaign_display_templates.save_as_new"))
  end
end
