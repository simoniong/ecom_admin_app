class Membership < ApplicationRecord
  belongs_to :company
  belongs_to :user
  belongs_to :group, optional: true

  enum :role, { member: 0, owner: 1 }

  validates :company_id, uniqueness: { scope: :user_id }
  validates :role, presence: true
  validate :owner_must_have_no_group
  validate :member_must_have_group_when_company_has_groups
  validate :group_must_belong_to_same_company

  # Dashboard is always granted — not listed here since it's not a selectable permission
  AVAILABLE_PERMISSIONS = %w[
    orders shipments tickets ad_campaigns
    shopify_stores ad_accounts email_accounts
    shipping_reminder_rules
  ].freeze

  def has_permission?(controller_name)
    owner? || controller_name.to_s == "dashboard" || permissions.include?(controller_name.to_s)
  end

  private

  def owner_must_have_no_group
    return unless owner?
    return if group_id.blank?

    errors.add(:group_id, :must_be_blank_for_owner)
  end

  def member_must_have_group_when_company_has_groups
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
