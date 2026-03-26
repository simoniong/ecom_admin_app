class Ticket < ApplicationRecord
  belongs_to :email_account
  belongs_to :customer, optional: true
  has_many :messages, dependent: :destroy

  enum :status, { new_ticket: 0, draft: 1, draft_confirmed: 2, closed: 3 }, default: :new_ticket

  validates :gmail_thread_id, presence: true, uniqueness: { scope: :email_account_id }
  validates :customer_email, presence: true
  validates :status, presence: true
  validates :draft_reply, presence: true, if: -> { draft? || draft_confirmed? }

  scope :by_recency, -> { order(last_message_at: :desc) }
  scope :for_user, ->(user) { joins(:email_account).where(email_accounts: { user_id: user.id }) }

  ALLOWED_TRANSITIONS = {
    "draft" => [ "draft_confirmed" ],
    "draft_confirmed" => [ "draft" ]
  }.freeze

  def submit_draft!(content)
    raise "Can only submit draft for new tickets" unless new_ticket?

    update!(
      draft_reply: content,
      draft_reply_at: Time.current,
      status: :draft
    )
  end

  def transition_status!(new_status)
    allowed = ALLOWED_TRANSITIONS[status] || []
    raise InvalidTransition, "Cannot transition from #{status} to #{new_status}" unless allowed.include?(new_status)

    update!(status: new_status)
  end

  class InvalidTransition < StandardError; end
end
