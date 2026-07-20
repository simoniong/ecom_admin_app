class LogisticsAccountsController < AdminController
  before_action :set_logistics_account

  def show
  end

  def update
    if @logistics_account.update(logistics_account_params)
      redirect_to logistics_account_path, notice: t("logistics_accounts.updated")
    else
      render :show, status: :unprocessable_entity
    end
  end

  def authenticate
    if @logistics_account.username.blank? || @logistics_account.password.blank?
      return redirect_to logistics_account_path, alert: t("logistics_accounts.missing_credentials")
    end

    result = RaydoService.new(@logistics_account).authenticate
    @logistics_account.update!(customer_id: result["customer_id"], customer_userid: result["customer_userid"])
    redirect_to logistics_account_path, notice: t("logistics_accounts.authenticate_success")
  rescue RaydoService::Error => e
    redirect_to logistics_account_path, alert: t("logistics_accounts.authenticate_failed", message: e.message)
  end

  private

  def set_logistics_account
    @logistics_account = current_company.raydo_logistics_account
  end

  def logistics_account_params
    attrs = params.require(:logistics_account).permit(:username, :password, :url1_base, :url2_base)
    # A blank password field means "keep the existing one" rather than clearing it.
    attrs.delete(:password) if attrs[:password].blank?
    attrs
  end
end
