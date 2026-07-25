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
      # 3,000 (factory default video_3_sec_watched) / 12,345 impressions => three_sec_rate.
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

    # Regression for a production 500: BackfillAdCreativesJob inserts ad_units
    # continuously (hourly self-heal). The old controller queried the same
    # `ad_creatives` relation twice -- once via `.pluck(:id)` to build the
    # metrics hash, once via `.to_a` to sort -- with five metrics queries
    # running in between. If an ad_unit became attributable in that window, the
    # second query returned a creative the first one never saw, so the metrics
    # hash lookup in #sort_creatives returned nil and `nil.public_send(...)`
    # raised NoMethodError. The fix materialises the creative set once and
    # derives both the metrics hash and the sort input from those same
    # records, so the two can no longer disagree.
    it "does not 500 when a creative gains its first attributable ad_unit mid-request" do
      stable = create(:ad_creative, ad_account: ad_account, name: "Stable Alpha")
      create(:ad_unit, ad_account: ad_account, ad_creative: stable)

      # No attributable ad_unit yet -- excluded from the initial query, exactly
      # like a creative the hourly backfill has not reached yet.
      late_arrival = create(:ad_creative, ad_account: ad_account, name: "Late Arriving Beta")

      fired = false
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        if !fired && sql.match?(/\A\s*SELECT/i) && sql.include?('"ad_creatives"') &&
            !sql.include?("INNER JOIN") && !sql.include?("GROUP BY")
          fired = true
          # Simulate BackfillAdCreativesJob committing a new attributable
          # ad_unit for a creative that the first query already ran past.
          create(:ad_unit, ad_account: ad_account, ad_creative: late_arrival)
        end
      end

      begin
        sign_in user
        get ad_creatives_path, params: { store_id: store.id }
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(fired).to eq(true) # sanity: the injection actually happened
      expect(response).to have_http_status(:success)
    end

    # Cheap guard against regressing back to the two-query shape: the
    # plain (non-aggregation) SELECT against ad_creatives must fire exactly
    # once per index request. batch_aggregated_metrics issues its own
    # ad_creatives-joining queries, but those all carry INNER JOIN/GROUP BY
    # and are excluded by the filter below.
    it "queries ad_creatives exactly once to build the index page" do
      creative = create(:ad_creative, ad_account: ad_account, name: "Single Query Creative")
      create(:ad_unit, ad_account: ad_account, ad_creative: creative)

      select_count = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        if sql.match?(/\A\s*SELECT/i) && sql.include?('"ad_creatives"') &&
            !sql.include?("INNER JOIN") && !sql.include?("GROUP BY")
          select_count += 1
        end
      end

      begin
        sign_in user
        get ad_creatives_path, params: { store_id: store.id }
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(response).to have_http_status(:success)
      expect(select_count).to eq(1)
    end

    # Pagination follows the products_controller.rb pattern: page/per_page
    # params, PER_PAGE_OPTIONS/PER_PAGE_DEFAULT constants. Unlike products,
    # the sort here happens in Ruby over computed metrics (see AdCreative::
    # CreativeMetrics) BEFORE the array is sliced into a page -- these specs
    # exist to catch a regression back to "paginate the DB query, then sort
    # each page separately", which would silently show the wrong rows.
    describe "pagination" do
      def creative_with_cpm(name:, spend:, impressions:)
        creative = create(:ad_creative, ad_account: ad_account, name: name)
        unit = create(:ad_unit, ad_account: ad_account, ad_creative: creative)
        create(:ad_unit_daily_metric, ad_unit: unit, date: Date.current, spend: spend, impressions: impressions)
        creative
      end

      it "returns different creatives on page 1 vs page 2" do
        # 25 is the smallest allowed PER_PAGE_OPTIONS value, so 26 records are
        # needed to force a real second page.
        # lifetime_spend (the default sort) is 0 for all of these (no
        # creative_synced_from_date/through_date on the account), so
        # sort_creatives' name-ascending tiebreak makes ordering deterministic.
        creatives = Array.new(26) { |i| creative_with_cpm(name: format("Creative %02d", i), spend: 10, impressions: 1_000) }

        sign_in user
        get ad_creatives_path, params: { store_id: store.id, per_page: 25, page: 1 }
        page1_names = creatives.map(&:name).select { |n| response.body.include?(n) }

        get ad_creatives_path, params: { store_id: store.id, per_page: 25, page: 2 }
        page2_names = creatives.map(&:name).select { |n| response.body.include?(n) }

        expect(page1_names.size).to eq(25)
        expect(page2_names.size).to eq(1)
        expect(page1_names & page2_names).to be_empty
      end

      it "falls back to the default per_page when the value is not an allowed option" do
        3.times { |i| creative_with_cpm(name: "Creative #{i}", spend: 10, impressions: 1_000) }

        sign_in user
        get ad_creatives_path, params: { store_id: store.id, per_page: 999 }

        expect(response).to have_http_status(:success)
        # 3 results fit on any per_page, so the pagination "showing" line (which
        # only renders once there's more than one page) can't prove the
        # fallback happened -- assert on the per_page selector's own selected
        # option instead, which always renders.
        doc = Nokogiri::HTML(response.body)
        selected_option = doc.at_css("select#per_page option[selected]")
        expect(selected_option.text.strip).to eq(AdCreativesController::PER_PAGE_DEFAULT.to_s)
      end

      it "does not error on an out-of-range page" do
        creative_with_cpm(name: "Only Creative", spend: 10, impressions: 1_000)

        sign_in user
        get ad_creatives_path, params: { store_id: store.id, page: 999 }

        expect(response).to have_http_status(:success)
        expect(response.body).to include("Only Creative")
      end

      it "puts the highest-metric creative on page 1 when sorting by that metric" do
        # Created FIRST, so a naive "paginate the DB query, then sort each
        # page" implementation would put these on page 1 -- but they have the
        # lowest cpm, so they must not be what determines page 1's contents.
        5.times { |i| creative_with_cpm(name: "Low CPM #{i}", spend: 1, impressions: 10_000) }
        # Created LAST (would land on a later page under naive DB-order
        # pagination), but has by far the highest cpm (500 / 1_000 * 1_000 =
        # 500 vs 0.1 for the ones above) -- must appear on page 1 once
        # sorting happens on the full set before slicing.
        winner = creative_with_cpm(name: "Winner Highest CPM", spend: 500, impressions: 1_000)

        sign_in user
        get ad_creatives_path, params: {
          store_id: store.id, sort_column: "cpm", sort_direction: "desc", per_page: 2, page: 1
        }

        expect(response).to have_http_status(:success)
        expect(response.body).to include(winner.name)
      end
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

    # A claim pushes next_attempt_at an hour out, so claiming accounts the page
    # is not showing would suppress an unrelated account's automatic heal.
    it "only claims the selected account when the page is filtered to one" do
      ad_account
      other = create(:ad_account, user: user, shopify_store: store, account_name: "Untouched")
      sign_in user

      post sync_ad_creatives_path(ad_account_id: ad_account.id)

      expect(other.reload.creative_backfill_next_attempt_at).to be_nil
      expect(ad_account.reload.creative_backfill_next_attempt_at).to be_present
    end

    it "does not claim an account belonging to another store" do
      ad_account
      other_store = create(:shopify_store, user: user)
      other = create(:ad_account, user: user, shopify_store: other_store, account_name: "Other Store")
      sign_in user

      post sync_ad_creatives_path(store_id: store.id)

      expect(other.reload.creative_backfill_next_attempt_at).to be_nil
      expect(ad_account.reload.creative_backfill_next_attempt_at).to be_present
    end
  end
end
