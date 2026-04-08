class InvitationAcceptancesController < ApplicationController
  layout "auth"

  before_action :set_invitation

  def show
    if user_signed_in?
      if current_user.membership_for(@invitation.company).present?
        redirect_to authenticated_root_path, alert: t("invitations.already_member")
        return
      end
      @state = :accept
    elsif find_user_by_invitation_email.present?
      @state = :login
    else
      @state = :register
      @user = User.new(email: @invitation.email)
    end
  end

  def accept
    if user_signed_in?
      accept_and_redirect(current_user)
    elsif params[:state] == "login"
      user = find_user_by_invitation_email
      if user&.valid_for_authentication? { user.valid_password?(params[:password]) }
        sign_in(user)
        accept_and_redirect(user)
      else
        @state = :login
        flash.now[:alert] = t("invitations.invalid_credentials")
        render :show, status: :unprocessable_entity
      end
    elsif params[:state] == "register"
      @user = User.new(
        email: @invitation.email,
        first_name: params[:first_name],
        last_name: params[:last_name],
        password: params[:password],
        password_confirmation: params[:password_confirmation]
      )
      if @user.save
        sign_in(@user)
        accept_and_redirect(@user)
      else
        @state = :register
        render :show, status: :unprocessable_entity
      end
    else
      redirect_to accept_invitation_path(token: @invitation.token)
    end
  end

  private

  def set_invitation
    @invitation = Invitation.pending.find_by!(token: params[:token])
  end

  def find_user_by_invitation_email
    User.find_for_database_authentication(email: @invitation.email)
  end

  def accept_and_redirect(user)
    if user.membership_for(@invitation.company).present?
      redirect_to authenticated_root_path, alert: t("invitations.already_member")
      return
    end

    @invitation.accept!(user)
    session[:company_id] = @invitation.company_id
    redirect_to authenticated_root_path, notice: t("invitations.accepted", company: @invitation.company.name)
  end
end
