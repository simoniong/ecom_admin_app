require "rails_helper"

# The Ads nav group (data-controller="nav-group") replaces the old flat
# Ad Campaigns / Ad Creatives top-level links, mirroring how Shipping,
# Packing, Products, Settings and Tickets each group their own children —
# see app/views/shared/_sidebar.html.erb.
RSpec.describe "Ads nav-group", type: :system do
  let(:owner) { create(:user) }

  before { sign_in_as(owner) }

  it "expands to reveal both 廣告活動 and 素材分析 when clicked" do
    visit authenticated_root_path

    within "nav" do
      expect(page).to have_no_css("#ads-menu", visible: :visible)
      click_button I18n.t("nav.ads")
      expect(page).to have_css("#ads-menu", visible: :visible)
      expect(page).to have_link(I18n.t("nav.ad_campaigns"))
      expect(page).to have_link(I18n.t("nav.ad_creatives"))
    end
  end

  it "both links are reachable" do
    visit authenticated_root_path
    within("nav") { click_button I18n.t("nav.ads") }
    click_link I18n.t("nav.ad_campaigns")

    expect(page).to have_current_path(ad_campaigns_path)

    visit authenticated_root_path
    within("nav") { click_button I18n.t("nav.ads") }
    click_link I18n.t("nav.ad_creatives")

    expect(page).to have_current_path(ad_creatives_path)
  end

  # Mutation-test target: drop either has_permission? guard around the two
  # child links (or the has_ads_items OR) and this pair of specs must fail —
  # a member granted only one of the two permissions must never see the
  # other's link, even though the group itself is visible to both.
  it "shows only 廣告活動 to a member granted only the ad_campaigns permission" do
    member = create(:user)
    membership = member.membership_for(member.companies.first)
    membership.update!(role: :member, permissions: [ "ad_campaigns" ])
    sign_in_as(member)

    visit authenticated_root_path

    within "nav" do
      click_button I18n.t("nav.ads")
      expect(page).to have_link(I18n.t("nav.ad_campaigns"))
      expect(page).to have_no_link(I18n.t("nav.ad_creatives"))
    end
  end

  it "shows only 素材分析 to a member granted only the ad_creatives permission" do
    member = create(:user)
    membership = member.membership_for(member.companies.first)
    membership.update!(role: :member, permissions: [ "ad_creatives" ])
    sign_in_as(member)

    visit authenticated_root_path

    within "nav" do
      click_button I18n.t("nav.ads")
      expect(page).to have_link(I18n.t("nav.ad_creatives"))
      expect(page).to have_no_link(I18n.t("nav.ad_campaigns"))
    end
  end
end
