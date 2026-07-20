class ProductCustomsController < AdminController
  PER_PAGE_DEFAULT = 50
  PER_PAGE_OPTIONS = [ 25, 50, 100, 200, 300, 500 ].freeze

  def index
    @search = params[:search].presence
    @only_incomplete = params[:incomplete].present?
    @page = [ params[:page].to_i, 1 ].max
    per_page = Integer(params[:per_page], exception: false)
    @per_page = PER_PAGE_OPTIONS.include?(per_page) ? per_page : PER_PAGE_DEFAULT

    @shopify_store = current_shopify_store || visible_shopify_stores.first
    return redirect_to(shopify_stores_path, alert: t("products.no_store")) unless @shopify_store

    variants = filtered_variants
    @total_count = variants.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0
    @variants = variants.order("products.title ASC, product_variants.title ASC")
                        .offset((@page - 1) * @per_page).limit(@per_page)
  end

  private

  def filtered_variants
    scope = ProductVariant.joins(:product)
                          .where(products: { shopify_store_id: @shopify_store.id })
                          .includes(:product)
    if @search
      q = "%#{ActiveRecord::Base.sanitize_sql_like(@search)}%"
      scope = scope.where("product_variants.sku ILIKE :q OR product_variants.title ILIKE :q OR products.title ILIKE :q", q: q)
    end
    if @only_incomplete
      scope = scope.where("customs_name_zh IS NULL OR customs_name_zh = '' OR customs_name_en IS NULL OR customs_name_en = '' OR declared_value_usd IS NULL OR weight_grams IS NULL")
    end
    scope
  end
end
