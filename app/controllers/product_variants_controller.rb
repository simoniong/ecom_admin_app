class ProductVariantsController < AdminController
  before_action :set_variant, only: :update

  def update
    @variant.assign_attributes(variant_params)
    context = customs_touched? ? :customs : nil

    if @variant.save(context: context)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to(index_path_for_context, notice: t("product_variants.updated")) }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_back fallback_location: index_path_for_context, alert: @variant.errors.full_messages.join(", ") }
      end
    end
  end

  def bulk_update
    ids = Array(params[:variant_ids]).map(&:to_s)
    return redirect_to(products_path, alert: t("product_variants.bulk_no_selection")) if ids.empty?

    updates = {}
    updates[:unit_cost]      = params[:unit_cost]      if params[:unit_cost].to_s.strip.present?
    updates[:weight_grams]   = params[:weight_grams]   if params[:weight_grams].to_s.strip.present?
    updates[:packaging_cost] = params[:packaging_cost] if params[:packaging_cost].to_s.strip.present?
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

  # Enforce required-together on customs edits: any variant with a
  # blank required customs field aborts the whole batch (RecordInvalid),
  # nothing gets saved.
  def bulk_update_customs
    ids = Array(params[:variant_ids]).map(&:to_s)
    return redirect_to(product_customs_path, alert: t("product_variants.bulk_no_selection")) if ids.empty?

    updates = {}
    %i[customs_name_zh customs_name_en declared_value_usd hs_code import_hs_code weight_grams].each do |f|
      updates[f] = params[f] if params[f].to_s.strip.present?
    end
    return redirect_to(product_customs_path, alert: t("product_variants.bulk_no_fields_customs")) if updates.empty?

    scope = scoped_variants.where(id: ids)
    count = 0
    ProductVariant.transaction do
      scope.find_each do |v|
        v.assign_attributes(updates)
        v.save!(context: :customs) # enforce required-together on customs edits
        count += 1
      end
    end
    redirect_to product_customs_path(request.query_parameters.slice(:store_id, :search, :per_page, :page, :incomplete)),
                notice: t("product_variants.bulk_updated", count: count)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to product_customs_path, alert: e.record.errors.full_messages.join(", ")
  end

  private

  def scoped_variants
    store_ids = visible_shopify_stores.pluck(:id)
    ProductVariant.joins(:product).where(products: { shopify_store_id: store_ids })
  end

  def set_variant
    @variant = scoped_variants.find(params[:id])
  end

  # The cost page and the customs page both PATCH this same #update action
  # (inline cell edit); the request carries context=customs when it originated
  # on the customs page so the HTML fallback redirect and the turbo_stream row
  # partial (see update.turbo_stream.erb) match the page the edit came from.
  def index_path_for_context
    params[:context] == "customs" ? product_customs_path : products_path
  end

  # Cost edits (unit_cost/weight_grams/packaging_cost via variant_params) must
  # keep saving on the default context. Only treat the record as a customs
  # edit — and enforce the required-together validation — when a customs-only
  # field was actually submitted. weight_grams is deliberately excluded: it is
  # shared with the cost page, so editing it alone from either page must not
  # flip the record into the stricter :customs context.
  def customs_touched?
    pv = params[:product_variant]
    return false unless pv

    %w[customs_name_zh customs_name_en declared_value_usd hs_code import_hs_code].any? { |k| pv.key?(k) }
  end

  def variant_params
    params.require(:product_variant).permit(
      :unit_cost, :weight_grams, :packaging_cost,
      :customs_name_zh, :customs_name_en, :declared_value_usd, :hs_code, :import_hs_code
    )
  end
end
