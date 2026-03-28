class AdAccountsController < AdminController
  before_action :set_ad_account, only: [ :show, :destroy ]

  def index
    @ad_accounts = current_user.ad_accounts.order(created_at: :desc)
  end

  def show; end

  def destroy
    @ad_account.destroy
    redirect_to ad_accounts_path, notice: t("ad_accounts.disconnect_success")
  end

  private

  def set_ad_account
    @ad_account = current_user.ad_accounts.find(params[:id])
  end
end
