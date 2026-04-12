class EmailAccountsController < AdminController
  before_action :set_email_account, only: [ :show, :update, :destroy ]

  def index
    @email_accounts = current_company.email_accounts.order(created_at: :desc)
  end

  def show
  end

  def update
    if @email_account.update(send_window_params)
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
    @email_account = current_company.email_accounts.find(params[:id])
  end

  def send_window_params
    params.require(:email_account).permit(:send_window_from_hour, :send_window_from_minute, :send_window_to_hour, :send_window_to_minute, :discord_agent_mention)
  end
end
