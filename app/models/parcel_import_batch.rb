# A staged Excel import, held in the database (never in cache — see design
# doc §4.2.1). An in-flight import is business state: it carries money
# figures the user has already reviewed on the preview page, so it must
# survive across requests landing on different app containers, and it
# doubles as an audit trail of who imported what, from which file, and when.
class ParcelImportBatch < ApplicationRecord
  belongs_to :shopify_store
  belongs_to :user

  STATUSES = %w[pending completed].freeze

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :row_count, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :pending, -> { where(status: "pending") }

  def pending?
    status == "pending"
  end

  def completed?
    status == "completed"
  end
end
