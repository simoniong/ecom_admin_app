require "rails_helper"

RSpec.describe SyncStatus do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }
  let(:store_a) { create(:shopify_store, user: user, company: company, name: "Store A") }
  let(:store_b) { create(:shopify_store, user: user, company: company, name: "Store B") }
  let(:meta_account) { create(:ad_account, user: user, company: company, account_name: "Meta Account") }
  let(:google_account) { create(:ad_account, :google, user: user, company: company, account_name: "Google Account") }

  before { travel_to at(12) }

  def at(hour, minute = 0)
    Time.zone.local(2026, 10, 23, hour, minute, 0)
  end

  def record(target, source:, started_at:, status: "succeeded", message: nil)
    create(:sync_run, target: target, source: source, status: status, error_message: message,
                      started_at: started_at, finished_at: (started_at unless status == "running"))
  end

  def stores(*records)
    ShopifyStore.where(id: records.map(&:id))
  end

  def ad_accounts(*records)
    AdAccount.where(id: records.map(&:id))
  end

  def sync_status(store_scope: ShopifyStore.none, ad_scope: AdAccount.none, as: user)
    described_class.new(company: company, store_scope: store_scope, ad_scope: ad_scope, user: as)
  end

  def source_for(status, key)
    status.sources.find { |source| source.key == key }
  end

  it "is succeeded with last_success_at = oldest latest success across units" do
    record(store_a, source: "shopify_metrics", started_at: at(10, 0))
    record(store_b, source: "shopify_metrics", started_at: at(10, 30))

    status = sync_status(store_scope: stores(store_a, store_b))
    source = source_for(status, "shopify_metrics")

    expect(status.sources.map(&:key)).to eq(SyncRun::SOURCES)
    expect(source.state).to eq(:succeeded)
    expect(source.last_success_at).to eq(at(10, 0))
    expect(source.failures).to be_empty
    expect(source.signature).to be_nil
    # The three sources without runs are ignored rather than held against green.
    expect(status.badge).to eq(state: :ok, failed_count: 0, running_count: 0, updated_at: at(10, 0))
  end

  it "is running if any unit's latest run is running" do
    record(store_a, source: "shopify_metrics", started_at: at(10, 0))
    record(store_b, source: "shopify_metrics", status: "running", started_at: at(11, 55))

    status = sync_status(store_scope: stores(store_a, store_b))

    expect(source_for(status, "shopify_metrics").state).to eq(:running)
    expect(status.badge).to include(state: :running, failed_count: 0, running_count: 1)
    expect(status).to be_running
  end

  it "is failed if any unit failed, listing the failing store and message" do
    record(store_a, source: "shopify_metrics", started_at: at(10, 0))
    record(store_b, source: "shopify_metrics", status: "failed", started_at: at(11, 0), message: "X: y")

    status = sync_status(store_scope: stores(store_a, store_b))
    source = source_for(status, "shopify_metrics")

    expect(source.state).to eq(:failed)
    expect(source.failures).to eq([ { target_name: store_b.name, message: "X: y" } ])
    expect(source.signature).to be_present
    expect(source.acknowledged).to be(false)
    expect(status.badge).to include(state: :failed, failed_count: 1, running_count: 0)
  end

  it "treats a running row past its threshold as failed" do
    record(meta_account, source: "meta_ads", status: "running", started_at: at(11, 40))

    status = sync_status(ad_scope: ad_accounts(meta_account, google_account))
    source = source_for(status, "meta_ads")

    expect(source.state).to eq(:failed)
    expect(source.failures).to eq([ { target_name: "Meta Account",
                                      message: "Interrupted — no result after 15 minutes" } ])
    # The ad scope is split by platform, so the Google account sees none of this.
    expect(source_for(status, "google_ads").state).to eq(:never)
    expect(status).not_to be_running
    expect(status.badge).to include(state: :failed, failed_count: 1, running_count: 0)
  end

  it "reports never for a source with no runs" do
    status = sync_status(store_scope: stores(store_a), ad_scope: ad_accounts(meta_account, google_account))

    expect(status.sources.map(&:state)).to all(eq(:never))
    expect(status.badge).to eq(state: :never, failed_count: 0, running_count: 0, updated_at: nil)
  end

  it "is running while one unit runs even though another unit of the same source failed" do
    record(store_a, source: "shopify_metrics", status: "failed", started_at: at(11, 0), message: "boom")
    record(store_b, source: "shopify_metrics", status: "running", started_at: at(11, 55))

    status = sync_status(store_scope: stores(store_a, store_b))

    expect(source_for(status, "shopify_metrics").state).to eq(:failed)
    expect(status).to be_running
    expect(status.badge).to include(state: :failed, failed_count: 1, running_count: 1)
  end

  it "hides an acknowledged failure for that user only" do
    record(google_account, source: "google_ads", status: "failed", started_at: at(11, 0),
                           message: "Token expired — reconnect this ad account")

    status = sync_status(ad_scope: ad_accounts(google_account))
    ack = status.acknowledge!(:google_ads)

    expect(ack).to have_attributes(user: user, company: company, source: "google_ads", acknowledged_at: at(12))
    expect(source_for(status, "google_ads").acknowledged).to be(true)
    expect(status.badge).to include(state: :ok, failed_count: 0)

    others = sync_status(ad_scope: ad_accounts(google_account), as: create(:user))

    expect(source_for(others, "google_ads").acknowledged).to be(false)
    expect(others.badge).to include(state: :failed, failed_count: 1)
  end

  it "refuses to acknowledge a source it does not know" do
    expect { sync_status.acknowledge!(:shopify_inventory) }
      .to raise_error(ArgumentError, /shopify_inventory/)
  end

  it "has no updated_at when an acknowledged source has never succeeded, even though another source has" do
    record(google_account, source: "google_ads", status: "failed", started_at: at(11),
                           message: "Token expired — reconnect this ad account")
    record(store_a, source: "shopify_metrics", started_at: at(10, 30))

    status = sync_status(store_scope: stores(store_a), ad_scope: ad_accounts(google_account))
    status.acknowledge!(:google_ads)
    status = sync_status(store_scope: stores(store_a), ad_scope: ad_accounts(google_account))

    expect(source_for(status, "google_ads").acknowledged).to be(true)
    # google_ads is acknowledged (not :never — it has a failed run), so the badge
    # is :ok, but it never succeeded: updated_at must not borrow shopify_metrics'
    # success time and claim the whole scope is fresh.
    expect(status.badge).to include(state: :ok, failed_count: 0, updated_at: nil)
  end

  it "updates signature and acknowledged_at in place on a second acknowledge! for the same source" do
    record(google_account, source: "google_ads", status: "failed", started_at: at(10), message: "Error A")
    first = sync_status(ad_scope: ad_accounts(google_account)).acknowledge!(:google_ads)

    record(google_account, source: "google_ads", status: "failed", started_at: at(11), message: "Error B")
    second = travel_to(at(13)) { sync_status(ad_scope: ad_accounts(google_account)).acknowledge!(:google_ads) }

    expect(second.id).to eq(first.id)
    expect(second.signature).not_to eq(first.signature)
    expect(second.acknowledged_at).to eq(at(13))
    expect(SyncAcknowledgement.where(user: user, company: company, source: "google_ads").count).to eq(1)
  end

  it "re-raises a red when the error message changes after ack" do
    record(google_account, source: "google_ads", status: "failed", started_at: at(10), message: "Error A")
    travel_to(at(10, 30)) { sync_status(ad_scope: ad_accounts(google_account)).acknowledge!(:google_ads) }

    record(google_account, source: "google_ads", status: "failed", started_at: at(11), message: "Error B")
    status = sync_status(ad_scope: ad_accounts(google_account))

    expect(source_for(status, "google_ads").acknowledged).to be(false)
    expect(status.badge).to include(state: :failed, failed_count: 1)
  end

  it "keeps it hidden when a later failure has the same (normalised) message" do
    record(google_account, source: "google_ads", status: "failed", started_at: at(10),
                           message: "Timed out at 2026-10-23T10:00:00Z")
    travel_to(at(10, 30)) { sync_status(ad_scope: ad_accounts(google_account)).acknowledge!(:google_ads) }

    record(google_account, source: "google_ads", status: "failed", started_at: at(11),
                           message: "Timed out at 2026-10-23T11:00:00Z")
    status = sync_status(ad_scope: ad_accounts(google_account))

    expect(source_for(status, "google_ads").acknowledged).to be(true)
    expect(status.badge).to include(state: :ok, failed_count: 0)
  end

  it "re-raises a red after an intervening success, even with the same message" do
    record(google_account, source: "google_ads", status: "failed", started_at: at(9), message: "boom")
    travel_to(at(9, 30)) { sync_status(ad_scope: ad_accounts(google_account)).acknowledge!(:google_ads) }

    record(google_account, source: "google_ads", started_at: at(10))
    record(google_account, source: "google_ads", status: "failed", started_at: at(11), message: "boom")
    status = sync_status(ad_scope: ad_accounts(google_account))

    expect(source_for(status, "google_ads").acknowledged).to be(false)
    expect(status.badge).to include(state: :failed, failed_count: 1)
  end

  it "an ack made in one store scope does not hide a different failing set" do
    record(store_a, source: "shopify_metrics", started_at: at(10))
    record(store_b, source: "shopify_metrics", status: "failed", started_at: at(10), message: "boom")

    both = sync_status(store_scope: stores(store_a, store_b))
    travel_to(at(10, 30)) { both.acknowledge!(:shopify_metrics) }

    expect(source_for(both, "shopify_metrics").acknowledged).to be(true)

    record(store_a, source: "shopify_metrics", status: "failed", started_at: at(11), message: "boom")
    only_a = sync_status(store_scope: stores(store_a))

    expect(source_for(only_a, "shopify_metrics").acknowledged).to be(false)
    expect(only_a.badge).to include(state: :failed, failed_count: 1)
  end

  it "limits units to the given scopes" do
    record(store_a, source: "shopify_metrics", started_at: at(10))
    record(store_b, source: "shopify_metrics", status: "failed", started_at: at(11), message: "boom")

    status = sync_status(store_scope: stores(store_a))
    source = source_for(status, "shopify_metrics")

    expect(source.state).to eq(:succeeded)
    expect(source.failures).to be_empty
    expect(source.history.map(&:target_id)).to eq([ store_a.id ])
    expect(status.badge).to include(state: :ok, failed_count: 0)
  end

  it "shows at most 5 history rows newest first" do
    (5..11).each { |hour| record(store_a, source: "shopify_metrics", started_at: at(hour)) }

    history = source_for(sync_status(store_scope: stores(store_a)), "shopify_metrics").history

    expect(history.map(&:started_at)).to eq([ at(11), at(10), at(9), at(8), at(7) ])
  end
end
