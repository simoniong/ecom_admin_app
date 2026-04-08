class InvitationsController < AdminController
  before_action :require_owner!, only: [ :index, :create, :destroy ]
  skip_before_action :authorize_page!, only: [ :show, :accept ]

  def index
    @memberships = current_company.memberships.includes(:user).order(created_at: :asc)
    @invitations = current_company.invitations.pending.order(created_at: :desc)
    @invitation = current_company.invitations.build
  end

  def create
    @invitation = current_company.invitations.build(invitation_params)
    @invitation.invited_by = current_user
    @invitation.role = params.dig(:invitation, :role).presence_in(Invitation.roles.keys) || "member"

    if @invitation.save
      InvitationMailer.invite(@invitation).deliver_later
      redirect_to invitations_path, notice: t("invitations.sent")
    else
      @memberships = current_company.memberships.includes(:user).order(created_at: :asc)
      @invitations = current_company.invitations.pending.order(created_at: :desc)
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    invitation = current_company.invitations.pending.find(params[:id])
    invitation.destroy
    redirect_to invitations_path, notice: t("invitations.cancelled")
  end

  def show
    @invitation = Invitation.pending.find_by!(token: params[:token])
  end

  def accept
    @invitation = Invitation.pending.find_by!(token: params[:token])

    if current_user.membership_for(@invitation.company).present?
      redirect_to authenticated_root_path, alert: t("invitations.already_member")
      return
    end

    @invitation.accept!(current_user)
    session[:company_id] = @invitation.company_id
    redirect_to authenticated_root_path, notice: t("invitations.accepted", company: @invitation.company.name)
  end

  private

  def require_owner!
    unless current_membership&.owner?
      redirect_to authenticated_root_path, alert: t("companies.no_permission")
    end
  end

  def invitation_params
    params.require(:invitation).permit(:email, permissions: [])
  end
end
