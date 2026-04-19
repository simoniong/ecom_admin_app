module GroupAssignable
  extend ActiveSupport::Concern

  included do
    belongs_to :group, optional: true
    validate :group_required_when_company_has_groups
    validate :group_must_belong_to_same_company
  end

  private

  def group_required_when_company_has_groups
    return if group_id.present?
    return if company.blank?
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
