class BackfillAdCreativesJob < ApplicationJob
  queue_as :default

  def perform(ad_account_id:, days: 90)
    account = AdAccount.find_by(id: ad_account_id)
    return if account.nil?
    return if account.token_expired?

    # Only a clean run clears the backoff; a failed run leaves the schedule
    # set by the claim in place so the next attempt is spaced out.
    #
    # Note the interaction with the manual claim: an already caught-up account
    # hits `call`'s early return, gets `true`, and the release clears the
    # 1-hour window the manual claim just wrote, so the button can be pressed
    # again right away. That is benign — the run it would start is another
    # no-op early return — and `call`'s advisory lock, not this window, is what
    # keeps two real runs off one account.
    account.release_backfill_slot! if AdCreativeBackfillService.new(account).call(days: days)
  rescue => e
    Rails.logger.error("[BackfillAdCreatives] account=#{ad_account_id}: #{e.message}")
  end
end
