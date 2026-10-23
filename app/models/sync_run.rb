class SyncRun < ApplicationRecord
  class Failed < StandardError; end

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

  # Wraps a sync unit of work: takes over the placeholder row the Dashboard's
  # Sync action pre-created for this batch if there is one, otherwise records a
  # fresh running row, yields, and marks it succeeded/failed. Always re-raises
  # so existing job error handling (log and continue) is unchanged.
  def self.track(source:, target:, trigger:, batch_id: nil)
    run = claim_placeholder(source: source, target: target, batch_id: batch_id) || create!(
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

  # Records a single finished failed run, e.g. for an expired-token skip that
  # never started any work. Claims this batch's placeholder the same way .track
  # does, so an expired-token skip doesn't leave a "running" row occupying a
  # history slot alongside the failed one.
  def self.record_failure(source:, target:, trigger:, message:, batch_id: nil)
    now = Time.current
    claimed = claim_placeholder(source: source, target: target, batch_id: batch_id)

    if claimed
      claimed.update!(status: "failed", finished_at: now, error_message: message)
      return claimed
    end

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

  # Shared by .track and .record_failure: takes over the placeholder row the
  # Dashboard's Sync action pre-created for this unit under this batch, so the
  # job the click enqueued reports into the row the badge is already showing.
  #
  # The batch id is what makes that safe: a scheduled auto run, or a manual run
  # someone started elsewhere, carries no batch and so records its own row
  # instead of eating this one. The single UPDATE ... RETURNING is what makes it
  # exclusive — two jobs racing for the same placeholder cannot both claim it,
  # and an unclaimed placeholder just goes stale through STALE_AFTER.
  def self.claim_placeholder(source:, target:, batch_id:)
    return nil if batch_id.blank?

    now = Time.current
    find_by_sql([ <<~SQL.squish, now, now, batch_id, source, target.class.polymorphic_name, target.id ]).first
      UPDATE sync_runs SET placeholder = FALSE, started_at = ?, updated_at = ?
      WHERE id = (
        SELECT id FROM sync_runs
        WHERE placeholder = TRUE AND batch_id = ? AND source = ?
          AND target_type = ? AND target_id = ?
        LIMIT 1 FOR UPDATE SKIP LOCKED
      )
      RETURNING *
    SQL
  end
  private_class_method :claim_placeholder

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
