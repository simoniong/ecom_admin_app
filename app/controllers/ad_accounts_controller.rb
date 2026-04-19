class AdAccountsController < AdminController
  before_action :set_ad_account, only: [ :show, :update, :destroy ]
  before_action :require_owner_for_group_update, only: [ :update ]

  def index
    @ad_accounts = visible_ad_accounts.order(created_at: :desc)
  end

  def show; end

  def update
    if @ad_account.update(ad_account_params)
      redirect_to ad_account_path(@ad_account), notice: t("ad_accounts.group_updated")
    else
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    @ad_account.destroy
    redirect_to ad_accounts_path, notice: t("ad_accounts.disconnect_success")
  end

  private

  def set_ad_account
    @ad_account = visible_ad_accounts.find(params[:id])
  end

  def ad_account_params
    params.require(:ad_account).permit(:group_id)
  end

  def require_owner_for_group_update
    return if current_membership&.owner?

    redirect_to ad_account_path(@ad_account), alert: t("companies.no_permission")
  end
end
