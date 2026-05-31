class SyncShopifyProductsService
  def initialize(shopify_store)
    @store = shopify_store
    @shopify = ShopifyService.new(shopify_store)
    @synced_products = 0
    @synced_variants = 0
  end

  def call
    Rails.logger.info("[SyncProducts] start store=#{@store.shop_domain}")
    sync_started_at = Time.current

    update_store_currency
    sync_all_products

    @store.update!(products_synced_at: sync_started_at)
    Rails.logger.info("[SyncProducts] done #{@synced_products} products, #{@synced_variants} variants")
    { products: @synced_products, variants: @synced_variants }
  end

  private

  def update_store_currency
    shop = @shopify.fetch_shop
    @store.update!(currency: shop["currency"]) if shop["currency"].present?
  end

  def sync_all_products
    since_id = nil
    loop do
      batch = @shopify.fetch_all_products(since_id: since_id)
      break if batch.empty?
      batch.each { |sp| upsert_product(sp) }
      since_id = batch.last["id"]
      break if batch.size < 250
    end
  end

  def upsert_product(sp)
    product = @store.products.find_or_initialize_by(shopify_product_id: sp["id"])
    product.assign_attributes(
      title: sp["title"],
      handle: sp["handle"],
      status: sp["status"],
      image_url: sp.dig("image", "src"),
      shopify_data: sp
    )
    product.save!
    @synced_products += 1

    (sp["variants"] || []).each { |sv| upsert_variant(product, sv) }
  end

  def upsert_variant(product, sv)
    variant = product.product_variants.find_or_initialize_by(shopify_variant_id: sv["id"])
    variant.sku = sv["sku"]
    variant.title = sv["title"]
    variant.price = sv["price"]
    variant.currency = @store.currency
    variant.shopify_data = sv
    # Never overwrite admin-edited unit_cost / weight_grams.
    variant.save!
    @synced_variants += 1
  end
end
