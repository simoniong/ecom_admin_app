class ProductVariantsController < AdminController
  before_action :set_variant, only: :update

  def update
    if @variant.update(variant_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to products_path, notice: t("product_variants.updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_to products_path, alert: @variant.errors.full_messages.join(", ") }
      end
    end
  end

  private

  def scoped_variants
    store_ids = visible_shopify_stores.pluck(:id)
    ProductVariant.joins(:product).where(products: { shopify_store_id: store_ids })
  end

  def set_variant
    @variant = scoped_variants.find(params[:id])
  end

  def variant_params
    params.require(:product_variant).permit(:unit_cost, :weight_grams)
  end
end
