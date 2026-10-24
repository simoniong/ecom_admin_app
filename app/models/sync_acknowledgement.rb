class SyncAcknowledgement < ApplicationRecord
  belongs_to :user
  belongs_to :company

  validates :source, presence: true, inclusion: { in: SyncRun::SOURCES }
  validates :signature, presence: true
  validates :acknowledged_at, presence: true
  validates :user_id, uniqueness: { scope: [ :company_id, :source ] }
end
