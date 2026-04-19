class Invitation < ApplicationRecord
  belongs_to :company
  belongs_to :invited_by, class_name: "User"
  belongs_to :group, optional: true

  enum :role, { member: 0, owner: 1 }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { scope: :company_id, message: :already_invited,
                                  conditions: -> { where(accepted_at: nil) } }
  validates :token, presence: true, uniqueness: true
  validate :owner_invitation_must_have_no_group
  validate :member_invitation_must_have_group_when_company_has_groups
  validate :group_must_belong_to_same_company

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
        permissions: permissions,
        group: (member? ? group : nil)
      )
    end
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def owner_invitation_must_have_no_group
    return unless owner?
    return if group_id.blank?

    errors.add(:group_id, :must_be_blank_for_owner)
  end

  def member_invitation_must_have_group_when_company_has_groups
    return unless member?
    return if company.blank?
    return if group_id.present?
    return unless company.groups.exists?

    errors.add(:group_id, :required_when_company_has_groups)
  end

  def group_must_belong_to_same_company
    return if group.blank?
    return if company.blank?
    return if group.company_id == company_id

    errors.add(:group_id, :must_belong_to_same_company)
  end
end
