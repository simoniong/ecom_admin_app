require "rails_helper"

RSpec.describe "Dashboard sync status", type: :system do
  let!(:user) { create(:user) }
  let!(:company) { user.companies.first }
  let!(:store) { create(:shopify_store, user: user) }

  def sync_t(key, **options)
    I18n.t("dashboard.sync.#{key}", **options)
  end

  def open_drawer
    find("[data-sync-badge-state]").click
    expect(page).to have_css("[data-sync-status-target='drawer']", visible: :visible)
  end

  def manual_run
    create(:sync_run, company: company, target: store, source: "shopify_metrics",
                      trigger: "manual", started_at: 2.minutes.ago, finished_at: 2.minutes.ago)
  end

  # Reloading the metrics frame replaces its children, so a marker on one of
  # them disappearing is proof that the refresh actually landed.
  def mark_metrics
    page.execute_script("document.querySelector('#dashboard_metrics p').dataset.refreshMarker = '1'")
  end

  def today_range
    "#{I18n.l(Date.current)} — #{I18n.l(Date.current)}"
  end

  it "shows a green badge with the last update time" do
    create(:sync_run, company: company, target: store, source: "shopify_metrics",
                      started_at: 5.minutes.ago, finished_at: 5.minutes.ago)
    create(:sync_run, company: company, target: store, source: "shopify_orders",
                      started_at: 5.minutes.ago, finished_at: 5.minutes.ago)

    sign_in_as(user)
    visit authenticated_root_path

    expect(page).to have_css("[data-sync-badge-state='ok']")
    expect(page).to have_content(sync_t(:updated_ago, time: "5 minutes"))
  end

  it "shows a neutral badge and never rows when nothing has ever synced" do
    sign_in_as(user)
    visit authenticated_root_path

    expect(page).to have_css("[data-sync-badge-state='never']")
    expect(page).to have_content(sync_t(:never))

    open_drawer
    expect(page).to have_css("[data-sync-source-state='never']", count: 4)
  end

  it "opens the drawer with one row per source and its history labels" do
    meta_account = create(:ad_account, user: user)
    google_account = create(:ad_account, :google, user: user)
    create(:sync_run, company: company, target: store, source: "shopify_metrics", trigger: "auto")
    create(:sync_run, company: company, target: store, source: "shopify_orders", trigger: "manual")
    create(:sync_run, company: company, target: meta_account, source: "meta_ads", trigger: "auto")
    create(:sync_run, company: company, target: google_account, source: "google_ads", trigger: "manual")

    sign_in_as(user)
    visit authenticated_root_path
    open_drawer

    expect(page).to have_content(sync_t(:title))
    expect(page).to have_css("[data-sync-source]", count: 4)
    SyncRun::SOURCES.each { |key| expect(page).to have_content(sync_t("sources.#{key}")) }
    expect(page).to have_content(sync_t(:auto))
    expect(page).to have_content(sync_t(:manual))
    # The desktop drawer sits beside the numbers, so it must not dim them.
    expect(page).to have_css("[data-sync-status-target='backdrop']", visible: :hidden)
  end

  it "keeps a single badge frame when a range preset reloads the metrics" do
    create(:sync_run, company: company, target: store, source: "shopify_metrics",
                      started_at: 5.minutes.ago, finished_at: 5.minutes.ago)

    sign_in_as(user)
    visit authenticated_root_path
    click_on I18n.t("dashboard.ranges.today")

    expect(page).to have_css("#dashboard_metrics")
    expect(page).to have_css("turbo-frame#dashboard_sync_status", count: 1, visible: :all)
    expect(page).to have_css("[data-sync-badge-state='ok']")
  end

  it "shows a red badge with the error reason and hides it after acknowledging" do
    google_account = create(:ad_account, :google, user: user)
    create(:sync_run, company: company, source: "google_ads", target: google_account,
                      status: "failed", error_message: "GoogleAdsError: PERMISSION_DENIED")

    sign_in_as(user)
    visit authenticated_root_path

    expect(page).to have_content(sync_t(:failed, count: 1))
    click_on sync_t(:failed, count: 1)
    expect(page).to have_content("PERMISSION_DENIED")

    click_on sync_t(:acknowledge)

    expect(page).not_to have_content(sync_t(:failed, count: 1))
    # An acknowledgement only drops the failure from the pill; the row keeps it.
    expect(page).to have_content("PERMISSION_DENIED")
    # Nothing in scope has ever succeeded, so the green pill carries no time.
    expect(find("[data-sync-badge-state='ok']").text).to eq(sync_t(:updated_unknown))
  end

  it "turns the badge to running and disables the button when Sync is clicked" do
    # The placeholder rows are what the badge reads; running the jobs for real
    # would resolve them before the assertions below.
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    sign_in_as(user)
    visit authenticated_root_path
    find("[data-sync-button]").click

    expect(page).to have_content(sync_t(:running, count: 2))
    expect(page).to have_css("[data-sync-button][disabled]")
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "updates from running to done without reloading the page" do
    run = create(:sync_run, company: company, target: store, source: "shopify_metrics",
                            status: "running", started_at: 1.minute.ago, finished_at: nil)

    sign_in_as(user)
    visit authenticated_root_path
    expect(page).to have_content(sync_t(:running, count: 1))

    page.execute_script("window.dashboardNotReloaded = true")
    run.update!(status: "succeeded", finished_at: Time.current)

    expect(page).to have_content(sync_t(:updated_ago, time: "less than a minute"), wait: 7)
    expect(page.evaluate_script("window.dashboardNotReloaded")).to be(true)
  end

  it "keeps the drawer open across a poll" do
    create(:sync_run, company: company, target: store, source: "shopify_metrics",
                      status: "running", started_at: 1.minute.ago, finished_at: nil)

    sign_in_as(user)
    visit authenticated_root_path
    open_drawer

    # A poll replaces the frame's children, so the marker vanishing is proof
    # that one landed while the drawer was open.
    page.execute_script("document.querySelector(\"[data-sync-status-target='drawer']\").dataset.pollMarker = '1'")
    expect(page).to have_no_css("[data-poll-marker]", wait: 10)
    expect(page).to have_css("[data-sync-status-target='drawer']", visible: :visible)
  end

  it "does not re-open the drawer after navigating away and back" do
    sign_in_as(user)
    visit authenticated_root_path
    open_drawer

    within("aside") { click_on I18n.t("nav.orders") }
    expect(page).to have_no_css("[data-sync-badge-state]")
    within("aside") { click_on I18n.t("nav.dashboard") }

    expect(page).to have_css("[data-sync-badge-state]")
    expect(page).to have_css("[data-sync-status-target='drawer']", visible: :hidden)
  end

  it "offers a link to refresh the numbers after a manual sync finished" do
    manual_run

    sign_in_as(user)
    visit authenticated_root_path

    expect(page).to have_link(sync_t(:refresh_numbers))

    mark_metrics
    click_on sync_t(:refresh_numbers)

    # The frame has no src on the first paint, so the refresh falls back to a
    # Turbo visit; either way the numbers must come back.
    expect(page).to have_no_css("[data-refresh-marker]")
    expect(page).to have_content(I18n.t("dashboard.revenue"))
  end

  it "still offers the link when newer auto runs have filled the drawer history" do
    manual_run
    6.times do |index|
      create(:sync_run, company: company, target: store, source: "shopify_metrics",
                        started_at: (index + 1).seconds.ago, finished_at: (index + 1).seconds.ago)
    end

    sign_in_as(user)
    visit authenticated_root_path

    expect(page).to have_link(sync_t(:refresh_numbers))
  end

  it "refreshes the numbers for the range the user switched to, not the rendered one" do
    manual_run

    sign_in_as(user)
    visit authenticated_root_path
    click_on I18n.t("dashboard.ranges.today")

    expect(page).to have_content(today_range, wait: 10)

    mark_metrics
    click_on sync_t(:refresh_numbers)

    expect(page).to have_no_css("[data-refresh-marker]", wait: 10)
    expect(page).to have_content(today_range, wait: 10)
  end

  context "at phone width" do
    after { page.driver.browser.manage.window.resize_to(1400, 900) }

    it "uses a bottom sheet with a dimmed backdrop" do
      sign_in_as(user)
      page.driver.browser.manage.window.resize_to(375, 800)
      visit authenticated_root_path
      open_drawer

      expect(page).to have_css("[data-sync-status-target='drawer'].bottom-0", visible: :visible)
      expect(page).to have_css("[data-sync-status-target='backdrop']", visible: :visible)
    end

    it "still shows the refresh link" do
      manual_run

      sign_in_as(user)
      page.driver.browser.manage.window.resize_to(375, 800)
      visit authenticated_root_path

      expect(page).to have_link(sync_t(:refresh_numbers))
    end
  end
end
