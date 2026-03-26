class Fulfillment < ApplicationRecord
  belongs_to :order

  validates :shopify_fulfillment_id, presence: true, uniqueness: true

  scope :with_tracking, -> { where.not(tracking_number: [ nil, "" ]) }
end
