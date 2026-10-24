require "rails_helper"

RSpec.describe "Dashboard sync", type: :request do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }

  describe "POST /dashboard/sync" do
    it "enqueues the four jobs scoped to the selected store with trigger manual" do
      store = create(:shopify_store, user: user)
      other_store = create(:shopify_store, user: user)
      meta_account = create(:ad_account, user: user, shopify_store: store)
      google_account = create(:ad_account, :google, user: user, shopify_store: store)
      create(:ad_account, user: user, shopify_store: other_store, account_id: "act_other_store")

      sign_in user

      post dashboard_sync_path, params: { store_id: store.id }

      # Every job carries the batch its placeholders were created under, which
      # is what lets each one claim its own row instead of inserting another.
      batch_id = SyncRun.where(company_id: company.id).distinct.pluck(:batch_id).sole

      expect(SyncShopifyMetricsJob).to have_been_enqueued
        .with(store_ids: [ store.id ], trigger: "manual", sync_batch_id: batch_id)
      expect(SyncAllShopifyOrdersJob).to have_been_enqueued
        .with(store.id, trigger: "manual", sync_batch_id: batch_id)
      expect(SyncAdMetricsJob).to have_been_enqueued
        .with(ad_account_ids: [ meta_account.id ], trigger: "manual", sync_batch_id: batch_id)
      expect(SyncGoogleAdMetricsJob).to have_been_enqueued
        .with(ad_account_ids: [ google_account.id ], trigger: "manual", sync_batch_id: batch_id)

      # The other store is outside the selected scope, so no job may run for it.
      expect(SyncAllShopifyOrdersJob).to have_been_enqueued.exactly(:once)
      expect(SyncAllShopifyOrdersJob).not_to have_been_enqueued
        .with(other_store.id, trigger: "manual", sync_batch_id: batch_id)

      expect(response).to redirect_to(authenticated_root_path)
      expect(flash[:notice]).to eq(I18n.t("dashboard.sync.enqueued"))
    end

    it "pre-creates a placeholder per unit per source so the status is running immediately" do
      store = create(:shopify_store, user: user)
      meta_account = create(:ad_account, user: user, shopify_store: store)
      google_account = create(:ad_account, :google, user: user, shopify_store: store)

      sign_in user
      post dashboard_sync_path, params: { store_id: store.id }

      placeholders = SyncRun.where(company_id: company.id, placeholder: true, status: "running",
                                   trigger: "manual")
      expect(placeholders.map { |run| [ run.source, run.target ] }).to contain_exactly(
        [ "shopify_metrics", store ], [ "shopify_orders", store ],
        [ "meta_ads", meta_account ], [ "google_ads", google_account ]
      )
      # One batch for the whole click, so each job can claim exactly its own row.
      expect(placeholders.distinct.pluck(:batch_id).compact.size).to eq(1)

      get dashboard_sync_status_path, params: { store_id: store.id }
      expect(response.body).to include("running")
    end

    it "does not enqueue when a run in scope is already running" do
      store = create(:shopify_store, user: user)
      create(:sync_run, company: company, target: store, source: "shopify_metrics",
                        status: "running", started_at: Time.current, finished_at: nil)

      sign_in user

      expect {
        post dashboard_sync_path, params: { store_id: store.id }
      }.not_to have_enqueued_job

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t("dashboard.sync.already_running"))
    end

    it "enqueues nothing on a second request once the first's running placeholders are in scope" do
      store = create(:shopify_store, user: user)
      sign_in user

      post dashboard_sync_path, params: { store_id: store.id }

      expect {
        post dashboard_sync_path, params: { store_id: store.id }
      }.not_to have_enqueued_job

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t("dashboard.sync.already_running"))
    end

    it "removes the placeholder rows it created when enqueueing raises" do
      store = create(:shopify_store, user: user)
      sign_in user

      allow(SyncShopifyMetricsJob).to receive(:perform_later).and_raise(StandardError, "queue down")

      expect {
        post dashboard_sync_path, params: { store_id: store.id }
      }.to raise_error(StandardError, "queue down")

      expect(SyncRun.where(company_id: company.id, target: store)).to be_empty
    end

    it "keeps the placeholders of the jobs it already enqueued when a later enqueue raises" do
      store = create(:shopify_store, user: user)
      meta_account = create(:ad_account, user: user, shopify_store: store)
      sign_in user

      allow(SyncAllShopifyOrdersJob).to receive(:perform_later).and_raise(StandardError, "queue down")

      expect {
        post dashboard_sync_path, params: { store_id: store.id }
      }.to raise_error(StandardError, "queue down")

      # The metrics job is out on the queue and will do its work, so its
      # placeholder has to stay. The two that never got enqueued must not.
      expect(SyncShopifyMetricsJob).to have_been_enqueued
      expect(SyncRun.where(target: store, source: "shopify_metrics")).to exist
      expect(SyncRun.where(target: store, source: "shopify_orders")).to be_empty
      expect(SyncRun.where(target: meta_account, source: "meta_ads")).to be_empty
    end
  end

  describe "GET /dashboard/sync_status" do
    it "renders the status partial inside the dashboard_sync_status frame" do
      sign_in user
      get dashboard_sync_status_path
      expect(response).to have_http_status(:success)
      expect(response.body).to include('turbo-frame id="dashboard_sync_status"')
    end

    it "renders status for a company with no stores" do
      sign_in user
      get dashboard_sync_status_path
      expect(response).to have_http_status(:success)
    end

    it "does not include another company's runs" do
      other_user = create(:user)
      other_store = create(:shopify_store, user: other_user)
      create(:sync_run, company: other_user.companies.first, target: other_store, source: "shopify_metrics",
                        status: "failed", error_message: "other company failure message")

      sign_in user
      get dashboard_sync_status_path

      expect(response).to have_http_status(:success)
      expect(response.body).not_to include("other company failure message")
    end
  end

  describe "POST /dashboard/sync_status/acknowledge" do
    it "acknowledges a source for the current user" do
      store = create(:shopify_store, user: user)
      create(:sync_run, company: company, target: store, source: "shopify_metrics",
                        status: "failed", error_message: "boom")

      sign_in user

      expect {
        post dashboard_acknowledge_sync_path, params: { source: "shopify_metrics" }
      }.to change(SyncAcknowledgement, :count).by(1)

      ack = SyncAcknowledgement.last
      expect(ack.user).to eq(user)
      expect(ack.company).to eq(company)
      expect(ack.source).to eq("shopify_metrics")
      expect(response).to have_http_status(:success)
      expect(response.body).to include('turbo-frame id="dashboard_sync_status"')
    end

    it "rejects an unknown source" do
      sign_in user
      post dashboard_acknowledge_sync_path, params: { source: "bogus_source" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "does not acknowledge a source with no active failure" do
      sign_in user

      expect {
        post dashboard_acknowledge_sync_path, params: { source: "shopify_metrics" }
      }.not_to change(SyncAcknowledgement, :count)

      expect(response).to have_http_status(:success)
      expect(response.body).to include('turbo-frame id="dashboard_sync_status"')
    end
  end
end
