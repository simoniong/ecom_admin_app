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

  def bulk_update
    ids = Array(params[:variant_ids]).map(&:to_s)
    return redirect_to(products_path, alert: t("product_variants.bulk_no_selection")) if ids.empty?

    updates = {}
    updates[:unit_cost]    = params[:unit_cost]    if params[:unit_cost].to_s.strip.present?
    updates[:weight_grams] = params[:weight_grams] if params[:weight_grams].to_s.strip.present?
    return redirect_to(products_path, alert: t("product_variants.bulk_no_fields")) if updates.empty?

    scope = scoped_variants.where(id: ids)
    count = 0
    ProductVariant.transaction do
      scope.find_each do |v|
        v.assign_attributes(updates)
        v.save!
        count += 1
      end
    end
    redirect_to products_path(request.query_parameters.slice(:store_id, :search, :per_page, :page)),
                notice: t("product_variants.bulk_updated", count: count)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to products_path, alert: e.record.errors.full_messages.join(", ")
  end

  def matching_ids
    store = visible_shopify_stores.find_by(id: params[:store_id])
    return render(json: { ids: [] }) unless store

    scope = ProductVariant.joins(:product).where(products: { shopify_store_id: store.id })
    if params[:search].present?
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
      scope = scope.where(
        "product_variants.sku ILIKE :q OR product_variants.title ILIKE :q OR products.title ILIKE :q",
        q: pattern
      )
    end
    render json: { ids: scope.pluck(:id) }
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
