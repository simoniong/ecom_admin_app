class SyncRun < ApplicationRecord
  belongs_to :company
  belongs_to :target, polymorphic: true

  SOURCES = %w[shopify_metrics shopify_orders meta_ads google_ads].freeze

  STALE_AFTER = {
    "shopify_metrics" => 15.minutes,
    "shopify_orders" => 120.minutes,
    "meta_ads" => 15.minutes,
    "google_ads" => 120.minutes
  }.freeze

  UUID_REGEX = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i
  ISO_TIMESTAMP_REGEX = /\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\b/
  HEX_ID_REGEX = /\b[0-9a-f]{16,}\b/i
  DIGIT_RUN_REGEX = /\b\d{6,}\b/

  enum :status, { running: "running", succeeded: "succeeded", failed: "failed" }
  enum :trigger, { auto: "auto", manual: "manual" }, prefix: true

  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :target_type, inclusion: { in: %w[ShopifyStore AdAccount] }, allow_nil: true
  validates :trigger, presence: true
  validates :status, presence: true
  validates :started_at, presence: true

  # Wraps a sync unit of work: deletes any pre-created manual placeholder row
  # for the same (source, target) — see the Dashboard Sync action in Task 4 —
  # then records a running row, yields, and marks it succeeded/failed. Always
  # re-raises so existing job error handling (log and continue) is unchanged.
  def self.track(source:, target:, trigger:)
    where(
      source: source, target: target, status: "running",
      trigger: "manual", finished_at: nil
    ).delete_all

    run = create!(
      company_id: target.company_id,
      source: source,
      target: target,
      trigger: trigger,
      status: "running",
      started_at: Time.current
    )

    begin
      result = yield
    rescue StandardError => e
      run.update!(
        status: "failed",
        finished_at: Time.current,
        error_message: "#{e.class}: #{e.message}".truncate(2000)
      )
      raise
    end

    run.update!(status: "succeeded", finished_at: Time.current)
    result
  end

  # Records a single finished failed run, e.g. for an expired-token skip
  # that never started any work.
  def self.record_failure(source:, target:, trigger:, message:)
    now = Time.current
    create!(
      company_id: target.company_id,
      source: source,
      target: target,
      trigger: trigger,
      status: "failed",
      started_at: now,
      finished_at: now,
      error_message: message
    )
  end

  def self.normalize_error(message)
    message.to_s
      .gsub(UUID_REGEX, "")
      .gsub(ISO_TIMESTAMP_REGEX, "")
      .gsub(HEX_ID_REGEX, "")
      .gsub(DIGIT_RUN_REGEX, "")
      .squish
  end

  def self.purge_older_than(age)
    where("started_at < ?", age.ago).delete_all
  end

  def stale?
    running? && started_at < STALE_AFTER.fetch(source).ago
  end

  def effective_status
    stale? ? "failed" : status
  end

  def effective_error
    return interrupted_message if stale?

    error_message
  end

  private

  def interrupted_message
    minutes = STALE_AFTER.fetch(source).to_i / 60
    "Interrupted — no result after #{minutes} minutes"
  end
end
