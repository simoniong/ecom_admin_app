class Message < ApplicationRecord
  belongs_to :ticket

  validates :gmail_message_id, presence: true, uniqueness: true
  validates :from, presence: true

  scope :chronological, -> { order(sent_at: :asc) }

  def sent_at_in_zone(zone = "Asia/Shanghai")
    sent_at&.in_time_zone(zone)
  end
end
