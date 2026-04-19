class InvitationsController < AdminController
  before_action :require_owner!

  def index
    @memberships = current_company.memberships.includes(:user, :group).order(created_at: :asc)
    @invitations = current_company.invitations.pending.includes(:group).order(created_at: :desc)
    @invitation = current_company.invitations.build
  end

  def create
    @invitation = current_company.invitations.build(invitation_params)
    @invitation.invited_by = current_user
    @invitation.role = params.dig(:invitation, :role).presence_in(Invitation.roles.keys) || "member"
    @invitation.group_id = nil if @invitation.owner?

    if @invitation.save
      InvitationMailer.invite(@invitation).deliver_later
      redirect_to invitations_path, notice: t("invitations.sent")
    else
      @memberships = current_company.memberships.includes(:user, :group).order(created_at: :asc)
      @invitations = current_company.invitations.pending.includes(:group).order(created_at: :desc)
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    invitation = current_company.invitations.pending.find(params[:id])
    invitation.destroy
    redirect_to invitations_path, notice: t("invitations.cancelled")
  end

  private

  def require_owner!
    unless current_membership&.owner?
      redirect_to authenticated_root_path, alert: t("companies.no_permission")
    end
  end

  def invitation_params
    params.require(:invitation).permit(:email, :group_id, permissions: [])
  end
end
