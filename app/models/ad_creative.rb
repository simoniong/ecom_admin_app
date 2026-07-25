class AdCreative < ApplicationRecord
  ASSET_TYPES = %w[video image].freeze

  belongs_to :ad_account
  # nullify, not destroy: an ad going away must not delete the creative record
  has_many :ad_units, dependent: :nullify

  validates :asset_type, presence: true, inclusion: { in: ASSET_TYPES }
  validates :asset_id, presence: true,
    uniqueness: { scope: [ :ad_account_id, :asset_type ] }

  scope :video, -> { where(asset_type: "video") }
end
