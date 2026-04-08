class MembershipsController < AdminController
  skip_before_action :authorize_page!
  before_action :require_owner!
  before_action :set_membership, only: [ :edit, :update, :destroy ]
  before_action :prevent_self_action, only: [ :edit, :update, :destroy ]

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
    if @membership.user_id == current_user.id
      redirect_to invitations_path, alert: t("memberships.cannot_modify_self")
    end
  end

  def membership_params
    params.require(:membership).permit(permissions: [])
  end
end
