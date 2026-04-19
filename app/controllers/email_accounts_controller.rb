class EmailAccountsController < AdminController
  before_action :set_email_account, only: [ :show, :update, :destroy ]

  def index
    @email_accounts = visible_email_accounts.order(created_at: :desc)
  end

  def show
  end

  def update
    if email_account_group_params_present?
      return redirect_to(email_account_path(@email_account), alert: t("companies.no_permission")) unless current_membership&.owner?

      if @email_account.update(email_account_group_params)
        redirect_to email_account_path(@email_account), notice: t("email_accounts.group_updated")
      else
        render :show, status: :unprocessable_entity
      end
    elsif @email_account.update(email_account_params)
      redirect_to email_account_path(@email_account), notice: t("email_accounts.send_window_updated")
    else
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    @email_account.destroy
    redirect_to email_accounts_path, notice: t("email_accounts.disconnect_success")
  end

  private

  def set_email_account
    @email_account = visible_email_accounts.find(params[:id])
  end

  def email_account_params
    params.require(:email_account).permit(:send_window_from_hour, :send_window_from_minute, :send_window_to_hour, :send_window_to_minute, :discord_agent_mention)
  end

  def email_account_group_params_present?
    params.dig(:email_account, :group_id).present? || params.dig(:email_account).is_a?(ActionController::Parameters) && params[:email_account].key?(:group_id)
  end

  def email_account_group_params
    params.require(:email_account).permit(:group_id)
  end
end
