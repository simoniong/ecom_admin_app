class Ticket < ApplicationRecord
  belongs_to :email_account
  has_many :messages, dependent: :destroy

  enum :status, { new_ticket: 0, draft: 1, draft_confirmed: 2, closed: 3 }, default: :new_ticket

  validates :gmail_thread_id, presence: true, uniqueness: { scope: :email_account_id }
  validates :customer_email, presence: true
  validates :status, presence: true

  scope :by_recency, -> { order(last_message_at: :desc) }
  scope :for_user, ->(user) { joins(:email_account).where(email_accounts: { user_id: user.id }) }
end
