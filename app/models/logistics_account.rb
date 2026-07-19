class LogisticsAccount < ApplicationRecord
  belongs_to :company
  has_many :logistics_channels, dependent: :destroy

  encrypts :password, deterministic: false

  PROVIDERS = %w[raydo].freeze
  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :provider, uniqueness: { scope: :company_id }
end
