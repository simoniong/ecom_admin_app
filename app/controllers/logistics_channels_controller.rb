class LogisticsChannelsController < AdminController
  before_action :set_logistics_account
  before_action :require_logistics_account!, except: [ :index ]
  before_action :set_logistics_channel, only: [ :edit, :update, :destroy ]

  def index
    @channels = @logistics_account ? @logistics_account.logistics_channels.order(:name) : LogisticsChannel.none
  end

  def new
    @channel = @logistics_account.logistics_channels.build
  end

  def create
    @channel = @logistics_account.logistics_channels.build(channel_params)

    if @channel.save
      redirect_to logistics_channels_path, notice: t("logistics_channels.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @channel.update(channel_params)
      redirect_to logistics_channels_path, notice: t("logistics_channels.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @channel.destroy
    redirect_to logistics_channels_path, notice: t("logistics_channels.deleted")
  end

  # GET /logistics_channels/product_options — fetches the Raydo product list
  # (getProductList) live so the create/edit form can populate its dropdown.
  def product_options
    products = FulfillmentService.for(@logistics_account).product_list
    render json: products
  rescue FulfillmentService::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_logistics_account
    @logistics_account = current_company.logistics_accounts.find_by(provider: "raydo")
  end

  def require_logistics_account!
    return if @logistics_account

    respond_to do |format|
      format.json { render json: { error: t("logistics_channels.account_required") }, status: :unprocessable_entity }
      format.html { redirect_to logistics_account_path, alert: t("logistics_channels.account_required") }
    end
  end

  def set_logistics_channel
    @channel = @logistics_account.logistics_channels.find(params[:id])
  end

  def channel_params
    params.require(:logistics_channel).permit(
      :name, :product_id, :product_shortname, :shopify_carrier_name, :tracking_url_template, :label_print_type
    )
  end
end
