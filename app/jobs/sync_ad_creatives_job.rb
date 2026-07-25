class SyncAdCreativesJob < ApplicationJob
  queue_as :default

  BACKFILL_DAYS = 90

  def perform(company_id: nil, min_lookback_days: 7)
    scope = AdAccount.meta
    scope = scope.where(company_id: company_id) if company_id

    scope.find_each do |account|
      next if account.token_expired?

      if eligible_for_rolling?(account)
        sync_rolling(account, min_lookback_days)
      else
        heal(account)
      end
    rescue => e
      Rails.logger.error("[SyncAdCreatives] account=#{account.account_id}: #{e.message}")
    end
  end

  private

  # Rolling sync may only append next to an existing contiguous interval.
  # Writing recent days ahead of an unfinished backfill would punch a hole and
  # break the coverage invariant (spec §5.6).
  def eligible_for_rolling?(account)
    through = account.creative_synced_through_date
    account.creative_synced_from_date.present? && through.present? &&
      through >= account.today_in_zone - 1
  end

  def sync_rolling(account, min_lookback_days)
    today = account.today_in_zone
    lookback = [ attribution_window_days(account), min_lookback_days ].compact.max
    AdCreativeBackfillService.new(account).sync_range(today - (lookback - 1), today)
  end

  # Account-level attribution settings are not exposed on the stored record
  # yet, so the floor applies. Wired here so a future lookup has one home.
  def attribution_window_days(_account)
    nil
  end

  # An ineligible account must never be silently skipped: pre-existing accounts
  # get no connect event and a retry-exhausted backfill is never re-enqueued,
  # so this is the only recovery path (spec §5.6).
  def heal(account)
    Rails.logger.warn(
      "[SyncAdCreatives] ineligible account=#{account.account_id} " \
      "from=#{account.creative_synced_from_date} through=#{account.creative_synced_through_date}"
    )
    return unless account.claim_backfill_slot!

    BackfillAdCreativesJob.perform_later(ad_account_id: account.id, days: BACKFILL_DAYS)
  end
end
