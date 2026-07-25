class AdAccount < ApplicationRecord
  include GroupAssignable

  belongs_to :user
  belongs_to :company
  belongs_to :shopify_store, optional: true
  has_many :ad_campaigns, dependent: :destroy
  has_many :ad_daily_metrics, dependent: :destroy
  has_many :ad_creatives, dependent: :destroy
  has_many :ad_units, dependent: :destroy

  encrypts :access_token, deterministic: false

  validates :platform, presence: true, inclusion: { in: %w[meta] }
  validates :account_id, presence: true, uniqueness: { scope: [ :platform, :user_id ] }
  validates :access_token, presence: true

  scope :meta, -> { where(platform: "meta") }

  def token_expired?
    token_expires_at.present? && token_expires_at < Time.current
  end

  def token_expiring_soon?
    token_expires_at.present? && token_expires_at < 7.days.from_now
  end

  # Meta insights dates are in the ad account's own timezone, never the app's.
  def today_in_zone
    (ActiveSupport::TimeZone[timezone.to_s] || ActiveSupport::TimeZone["UTC"]).today
  end

  # Single atomic conditional UPDATE: checking the due time and advancing it
  # must not be two statements, or two concurrent runners both pass the check
  # and each enqueue a job (spec §5.6).
  #
  # next_attempt_at advances at CLAIM time, not on completion, so it also
  # guards against a still-running backfill without inspecting the queue.
  #
  # Manual claims bypass failure backoff (attempts > 0) because the user asked
  # for a retry, but still respect a 1-hour window set by a previous manual
  # click or a clean state, which is what stops rapid double-clicks. Manual
  # claims never increment attempts: that counter means "consecutive failures"
  # and drives both backoff and future alerting.
  def claim_backfill_slot!(manual: false)
    now = Time.current
    scope = AdAccount.where(id: id)

    scope = if manual
      scope.where(
        "creative_backfill_next_attempt_at IS NULL " \
        "OR creative_backfill_next_attempt_at <= ? " \
        "OR creative_backfill_attempts > 0", now
      )
    else
      scope.where(
        "creative_backfill_next_attempt_at IS NULL OR creative_backfill_next_attempt_at <= ?", now
      )
    end

    affected = if manual
      scope.update_all([ "creative_backfill_next_attempt_at = ?", now + 1.hour ])
    else
      scope.update_all(
        "creative_backfill_attempts = creative_backfill_attempts + 1, " \
        "creative_backfill_next_attempt_at = NOW() + " \
        "(LEAST(GREATEST(POWER(2, creative_backfill_attempts + 1), 1), 24) || ' hours')::interval"
      )
    end

    affected == 1
  end

  def release_backfill_slot!
    update_columns(creative_backfill_attempts: 0, creative_backfill_next_attempt_at: nil)
  end
end
