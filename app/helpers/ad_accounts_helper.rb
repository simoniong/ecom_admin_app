module AdAccountsHelper
  # Meta ad account `account_status` integer -> i18n status key.
  # https://developers.facebook.com/docs/marketing-api/reference/ad-account/
  META_ACCOUNT_STATUS_KEYS = {
    1 => :active,
    2 => :disabled,
    3 => :unsettled,
    7 => :pending_risk_review,
    8 => :pending_settlement,
    9 => :in_grace_period,
    100 => :pending_closure,
    101 => :closed,
    201 => :active,
    202 => :closed
  }.freeze

  def ad_account_status_key(account_status)
    META_ACCOUNT_STATUS_KEYS.fetch(account_status.to_i, :unknown)
  end

  # Only status 1 (ACTIVE) / 201 (ANY_ACTIVE) accounts can run ads.
  def ad_account_active?(account_status)
    ad_account_status_key(account_status) == :active
  end
end
