class Invitation < ApplicationRecord
  belongs_to :company
  belongs_to :invited_by, class_name: "User"

  enum :role, { member: 0, owner: 1 }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :token, presence: true, uniqueness: true

  before_validation :generate_token, on: :create

  scope :pending, -> { where(accepted_at: nil) }

  def accepted?
    accepted_at.present?
  end

  def accept!(user)
    transaction do
      update!(accepted_at: Time.current)
      Membership.create!(
        company: company,
        user: user,
        role: role,
        permissions: permissions
      )
    end
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end
end
