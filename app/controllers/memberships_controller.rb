class MembershipsController < AdminController
  skip_before_action :authorize_page!
  before_action :require_owner!
  before_action :set_membership, only: [ :edit, :update, :destroy ]
  before_action :prevent_self_action, only: [ :edit, :update, :destroy ]
  before_action :prevent_destroying_owner, only: [ :destroy ]

  def edit
  end

  def update
    if @membership.update(membership_params)
      redirect_to invitations_path, notice: t("memberships.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @membership.destroy
    redirect_to invitations_path, notice: t("memberships.removed")
  end

  private

  def require_owner!
    unless current_membership&.owner?
      redirect_to authenticated_root_path, alert: t("companies.no_permission")
    end
  end

  def set_membership
    @membership = current_company.memberships.find(params[:id])
  end

  def prevent_self_action
    return unless @membership.user_id == current_user.id

    redirect_to invitations_path, alert: t("memberships.cannot_modify_self")
  end

  def prevent_destroying_owner
    return unless @membership.owner?

    redirect_to invitations_path, alert: t("memberships.cannot_modify_owner")
  end

  def membership_params
    raw = params.fetch(:membership, {})
    permitted = raw.permit(:group_id, permissions: [])
    permitted[:permissions] = Array(permitted[:permissions]).reject(&:blank?).select do |p|
      Membership::AVAILABLE_PERMISSIONS.include?(p)
    end

    requested_role = raw[:role].to_s
    if Membership.roles.keys.include?(requested_role)
      permitted[:role] = requested_role
    end

    if permitted[:role] == "owner"
      permitted[:group_id] = nil
    else
      permitted[:group_id] = nil if permitted[:group_id].blank?
    end

    permitted
  end
end
