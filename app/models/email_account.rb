class EmailAccount < ApplicationRecord
  belongs_to :user
  belongs_to :company
  belongs_to :shopify_store, optional: true
  has_many :tickets, dependent: :destroy

  encrypts :access_token, deterministic: false
  encrypts :refresh_token, deterministic: false

  validates :email, presence: true, uniqueness: { scope: :user_id }
  validates :google_uid, presence: true, uniqueness: true
  validates :access_token, presence: true
  validates :refresh_token, presence: true

  validates :send_window_from_hour, numericality: { in: 0..23 }
  validates :send_window_from_minute, numericality: { in: 0..59 }
  validates :send_window_to_hour, numericality: { in: 0..23 }
  validates :send_window_to_minute, numericality: { in: 0..59 }
  validate :send_window_to_after_from

  def send_window_from
    send_window_from_hour * 60 + send_window_from_minute
  end

  def send_window_to
    send_window_to_hour * 60 + send_window_to_minute
  end

  private

  def send_window_to_after_from
    return unless send_window_from_hour && send_window_from_minute && send_window_to_hour && send_window_to_minute

    if send_window_to <= send_window_from
      errors.add(:base, :send_window_invalid)
    end
  end
end
