require "rails_helper"

RSpec.describe SyncRun, type: :model do
  it "is valid with valid attributes" do
    expect(create(:sync_run)).to be_valid
  end

  it "generates a UUID id" do
    expect(create(:sync_run).id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "requires source to be one of SOURCES" do
    run = build(:sync_run, source: "invalid_source")
    expect(run).not_to be_valid
  end

  it "requires target_type to be ShopifyStore or AdAccount" do
    run = build(:sync_run)
    run.target_type = "User"
    expect(run).not_to be_valid
  end

  describe ".track" do
    it "records a succeeded run around the block" do
      store = create(:shopify_store)
      result = SyncRun.track(source: "shopify_metrics", target: store, trigger: "auto") { :ok }
      run = SyncRun.last
      expect(result).to eq(:ok)
      expect(run).to have_attributes(status: "succeeded", trigger: "auto", target: store, company_id: store.company_id)
      expect(run.finished_at).to be_present
    end

    it "records a failed run and re-raises" do
      store = create(:shopify_store)
      expect {
        SyncRun.track(source: "shopify_orders", target: store, trigger: "manual") { raise ArgumentError, "boom" }
      }.to raise_error(ArgumentError, "boom")
      expect(SyncRun.last).to have_attributes(status: "failed", error_message: "ArgumentError: boom")
    end

    it "claims its batch's placeholder instead of inserting a second row" do
      store = create(:shopify_store)
      placeholder = create(:sync_run, :placeholder, source: "shopify_orders", target: store,
                                      started_at: 1.minute.ago)

      SyncRun.track(source: "shopify_orders", target: store, trigger: "manual",
                    batch_id: placeholder.batch_id) { :ok }

      expect(SyncRun.where(source: "shopify_orders", target: store).pluck(:id)).to eq([ placeholder.id ])
      expect(placeholder.reload).to have_attributes(status: "succeeded", placeholder: false)
      # The placeholder was created when Sync was clicked; the run started when
      # the job claimed it.
      expect(placeholder.started_at).to be > 1.minute.ago
    end

    it "leaves a manual batch's placeholder alone when an auto run overlaps it" do
      store = create(:shopify_store)
      placeholder = create(:sync_run, :placeholder, source: "shopify_orders", target: store)

      SyncRun.track(source: "shopify_orders", target: store, trigger: "auto") { :ok }

      expect(placeholder.reload).to have_attributes(status: "running", placeholder: true)
      expect(SyncRun.where(source: "shopify_orders", target: store).count).to eq(2)
    end

    it "leaves another batch's placeholder alone" do
      store = create(:shopify_store)
      placeholder = create(:sync_run, :placeholder, source: "shopify_orders", target: store)

      SyncRun.track(source: "shopify_orders", target: store, trigger: "manual",
                    batch_id: SecureRandom.uuid) { :ok }

      expect(placeholder.reload).to have_attributes(status: "running", placeholder: true)
      expect(SyncRun.where(source: "shopify_orders", target: store).count).to eq(2)
    end

    it "keeps both runs in history when two manual runs overlap on the same target" do
      store = create(:shopify_store)

      SyncRun.track(source: "shopify_orders", target: store, trigger: "manual") do
        SyncRun.track(source: "shopify_orders", target: store, trigger: "manual") { :ok }
      end

      expect(SyncRun.where(source: "shopify_orders", target: store).pluck(:status))
        .to eq(%w[succeeded succeeded])
    end
  end

  describe ".record_failure" do
    it "creates a single finished failed run" do
      store = create(:shopify_store)
      run = SyncRun.record_failure(
        source: "meta_ads", target: store, trigger: "manual",
        message: "Token expired — reconnect this ad account"
      )
      expect(run).to have_attributes(status: "failed", started_at: run.finished_at)
      expect(run.error_message).to eq("Token expired — reconnect this ad account")
    end

    it "claims its batch's placeholder for the same target" do
      store = create(:shopify_store)
      placeholder = create(:sync_run, :placeholder, source: "meta_ads", target: store)

      SyncRun.record_failure(
        source: "meta_ads", target: store, trigger: "manual", batch_id: placeholder.batch_id,
        message: "Token expired — reconnect this ad account"
      )

      expect(SyncRun.where(source: "meta_ads", target: store).pluck(:id)).to eq([ placeholder.id ])
      expect(placeholder.reload).to have_attributes(status: "failed", placeholder: false)
    end

    it "leaves another batch's placeholder alone" do
      store = create(:shopify_store)
      placeholder = create(:sync_run, :placeholder, source: "meta_ads", target: store)

      SyncRun.record_failure(
        source: "meta_ads", target: store, trigger: "auto",
        message: "Token expired — reconnect this ad account"
      )

      expect(placeholder.reload).to have_attributes(status: "running", placeholder: true)
      expect(SyncRun.where(source: "meta_ads", target: store).count).to eq(2)
    end
  end

  describe "#stale? and #effective_status/#effective_error" do
    it "treats a running row older than its source threshold as stale/failed" do
      run = create(:sync_run, source: "meta_ads", status: "running", started_at: 16.minutes.ago)
      expect(run.stale?).to be(true)
      expect(run.effective_status).to eq("failed")
      expect(run.effective_error).to include("15")
    end

    it "does not treat a fresh running row as stale" do
      run = create(:sync_run, source: "meta_ads", status: "running", started_at: 1.minute.ago)
      expect(run.stale?).to be(false)
      expect(run.effective_status).to eq("running")
      expect(run.effective_error).to be_nil
    end

    it "returns the stored error_message for a non-stale failed run" do
      run = create(:sync_run, status: "failed", error_message: "boom")
      expect(run.effective_status).to eq("failed")
      expect(run.effective_error).to eq("boom")
    end
  end

  describe ".normalize_error" do
    it "normalises volatile parts of error messages" do
      a = SyncRun.normalize_error("PERMISSION_DENIED request_id=8f3a9c0b1d2e4f5a at 2026-10-23T03:00:01Z")
      b = SyncRun.normalize_error("PERMISSION_DENIED request_id=11aa22bb33cc44dd at 2026-10-23T04:00:09Z")
      expect(a).to eq(b)
    end
  end

  describe ".purge_older_than" do
    it "purges runs older than the given age" do
      create(:sync_run, started_at: 8.days.ago)
      keep = create(:sync_run, started_at: 1.day.ago)
      expect(SyncRun.purge_older_than(7.days)).to eq(1)
      expect(SyncRun.all).to contain_exactly(keep)
    end
  end
end
