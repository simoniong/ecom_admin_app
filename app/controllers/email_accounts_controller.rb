class EmailAccountsController < AdminController
  before_action :set_email_account, only: [ :show, :destroy ]

  def index
    @email_accounts = current_company.email_accounts.order(created_at: :desc)
  end

  def show
  end

  def destroy
    @email_account.destroy
    redirect_to email_accounts_path, notice: t("email_accounts.disconnect_success")
  end

  private

  def set_email_account
    @email_account = current_company.email_accounts.find(params[:id])
  end
end
