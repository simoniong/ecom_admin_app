class LogisticsAccount < ApplicationRecord
  belongs_to :company
  has_many :logistics_channels, dependent: :destroy

  encrypts :password, deterministic: false

  PROVIDERS = %w[raydo].freeze
  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :provider, uniqueness: { scope: :company_id }

  # A malformed base URL (or one missing a scheme) would otherwise reach
  # HTTParty/URI inside RaydoService and blow up with URI::InvalidURIError.
  # Blank is allowed because an account may exist before its URLs are entered.
  validates :url1_base, :url2_base,
            format: { with: %r{\Ahttps?://.+\z}, message: :invalid_url },
            allow_blank: true
end
