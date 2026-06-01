class ShippingRateCardRatesController < AdminController
  before_action :require_owner!
  before_action :set_version
  before_action :set_rate, only: [ :update, :destroy ]

  def create
    rate = @version.rates.new(rate_params)
    if rate.save
      redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.rate_created")
    else
      redirect_to shipping_rate_card_versions_path, alert: rate.errors.full_messages.join(", ")
    end
  end

  def update
    if @rate.update(rate_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.rate_updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_to shipping_rate_card_versions_path, alert: @rate.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @rate.destroy
    redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.rate_deleted")
  end

  def import
    result = RateCardRateImporter.new(version: @version, text: params[:text]).call
    if result[:errors].empty?
      redirect_to shipping_rate_card_versions_path,
                  notice: t("shipping_rate_cards.bulk_import_done", count: result[:count])
    else
      flash[:rate_import_errors] = result[:errors]
      redirect_to shipping_rate_card_versions_path,
                  alert: t("shipping_rate_cards.bulk_import_errors")
    end
  end

  private

  def set_version
    @version = current_company.shipping_rate_card_versions.find(params[:shipping_rate_card_version_id])
  end

  def set_rate
    @rate = @version.rates.find(params[:id])
  end

  def rate_params
    params.require(:shipping_rate_card_rate).permit(:zone, :weight_min_kg, :weight_max_kg, :per_kg_rate_cny, :flat_fee_cny)
  end

  def require_owner!
    redirect_to(shipping_rate_card_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
