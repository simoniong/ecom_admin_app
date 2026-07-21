class Package < ApplicationRecord
  belongs_to :shopify_store
  belongs_to :order
  belongs_to :logistics_channel, optional: true
  has_many :package_items, dependent: :destroy

  validates :number, presence: true, uniqueness: { scope: :shopify_store_id }

  # e.g. "XMBDE2013094" — prefix + number zero-padded to at least 7 digits.
  def package_code
    "#{shopify_store.package_prefix}#{number.to_s.rjust(7, '0')}"
  end
end
