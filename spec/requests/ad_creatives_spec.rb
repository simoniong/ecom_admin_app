require "rails_helper"

RSpec.describe "AdCreatives", type: :request do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user) }
  let(:ad_account) { create(:ad_account, user: user, shopify_store: store) }

  describe "GET /ad_creatives" do
    it "returns success for an authenticated user" do
      sign_in user
      get ad_creatives_path
      expect(response).to have_http_status(:success)
    end

    it "redirects an unauthenticated user" do
      get ad_creatives_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "shows the empty state when there are no creatives" do
      sign_in user
      get ad_creatives_path
      expect(response.body).to include("No ad creatives found")
    end

    it "lists creatives with metrics" do
      creative = create(:ad_creative, ad_account: ad_account, name: "Toy Duck Demo v1")
      unit = create(:ad_unit, ad_account: ad_account, ad_creative: creative)
      create(:ad_unit_daily_metric, ad_unit: unit, date: Date.current, impressions: 12_345)

      sign_in user
      get ad_creatives_path, params: { store_id: store.id }

      expect(response.body).to include("Toy Duck Demo v1")
      # 3,000 (factory default video_continuous_2_sec_watched) / 12,345 impressions => two_sec_rate.
      # The table renders computed rates, not the raw impressions count, so assert on the rate.
      expect(response.body).to include("24.3%")
    end

    it "does not show creatives belonging to another user" do
      other_account = create(:ad_account, user: create(:user))
      other_creative = create(:ad_creative, ad_account: other_account, name: "Competitor Hook Alpha")
      # An attributable ad unit is required so this creative would actually render if tenant
      # scoping broke — without one it is excluded regardless, and the spec would pass vacuously.
      create(:ad_unit, ad_account: other_account, ad_creative: other_creative)

      sign_in user
      get ad_creatives_path

      expect(response.body).not_to include("Competitor Hook Alpha")
    end

    it "filters by ad account" do
      keep = create(:ad_creative, ad_account: ad_account, name: "Kept Creative Alpha")
      create(:ad_unit, ad_account: ad_account, ad_creative: keep)
      other = create(:ad_account, user: user, account_name: "Second")
      filtered = create(:ad_creative, ad_account: other, name: "Filtered Creative Beta")
      create(:ad_unit, ad_account: other, ad_creative: filtered)

      sign_in user
      get ad_creatives_path, params: { ad_account_id: ad_account.id }

      expect(response.body).to include(keep.name)
      expect(response.body).not_to include("Filtered Creative Beta")
    end

    it "falls back to the default range for an unparseable date" do
      sign_in user
      get ad_creatives_path, params: { from_date: "not-a-date" }
      expect(response).to have_http_status(:success)
    end

    it "rejects a sort column that is not allow-listed" do
      sign_in user
      get ad_creatives_path, params: { sort_column: "spend; DROP TABLE users" }
      expect(response).to have_http_status(:success)
    end

    it "excludes creatives whose only ad unit is multi_asset" do
      creative = create(:ad_creative, ad_account: ad_account, name: "Advantage Bundle Gamma")
      create(:ad_unit, ad_account: ad_account, ad_creative: creative, multi_asset: true)

      sign_in user
      get ad_creatives_path

      expect(response.body).not_to include("Advantage Bundle Gamma")
    end
  end

  describe "POST /ad_creatives/sync" do
    it "enqueues a backfill for each visible account" do
      ad_account
      sign_in user

      expect {
        post sync_ad_creatives_path
      }.to have_enqueued_job(BackfillAdCreativesJob).with(ad_account_id: ad_account.id, days: 90)
    end

    it "redirects back with a notice" do
      ad_account
      sign_in user

      post sync_ad_creatives_path

      expect(response).to redirect_to(ad_creatives_path)
      expect(flash[:notice]).to be_present
    end

    it "does not enqueue twice on a rapid second click" do
      ad_account
      sign_in user
      post sync_ad_creatives_path

      expect { post sync_ad_creatives_path }.not_to have_enqueued_job(BackfillAdCreativesJob)
    end
  end
end
