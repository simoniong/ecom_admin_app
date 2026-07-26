# Builds/refunds a Package for an order as it syncs. Called from
# SyncAllOrdersService#sync_order after the order is upserted.
class PackageAutoBuilder
  PAID_STATUSES = %w[paid partially_paid].freeze

  def initialize(order)
    @order = order
    @store = order.shopify_store
  end

  def call
    do_call
  rescue => e
    Rails.logger.error("[PackageAutoBuilder] Order##{@order.id} failed: #{e.class}: #{e.message}")
    nil
  end

  private

  # Refund of an EXISTING package must run regardless of packing_enabled? —
  # a store that has since turned packing off (or a package built before it
  # was disabled) must still see that package transition to refunded on a
  # full refund. packing_enabled? gates ONLY new-package creation below.
  #
  # Routes by how many packages the order currently has:
  #   >1  → frozen (split state): manual reorg only, no auto sync/refund.
  #   1   → smart_update the lone package (honoring override flags), or refund it.
  #   0   → build a new package if eligible.
  # Merging a split order back to one package (count → 1) resumes auto-sync.
  def do_call
    return unless @store

    packages = @store.packages.where(order_id: @order.id)
    count = packages.count

    return if count > 1 # frozen — see design doc Q1 (split state)

    if fully_refunded?
      existing = packages.first
      refund(existing) if existing
      return
    end

    if count == 1
      existing = packages.first
      smart_update(existing) unless existing.refunded?
      return
    end

    return unless @store.packing_enabled?
    return unless eligible?

    build_package
  end

  def fully_refunded?
    @order.financial_status == "refunded"
  end

  def cancelled?
    @order.shopify_data["cancelled_at"].present?
  end

  def eligible?
    PAID_STATUSES.include?(@order.financial_status) && !cancelled? && not_backfill?
  end

  # No-backfill guard: only build packages for orders placed at/after the
  # moment packing was switched on for this store. Without this, enabling
  # packing on an already-synced store would build packages for the store's
  # entire eligible order history on the next sync (see design doc: "只對開關
  # 打開後、新同步進來的訂單建包裹...不回溯既有舊訂單;歷史 backfill 是 Phase 4").
  # Deliberately NOT applied to the refund path (fully_refunded? in do_call) —
  # a refund on any existing package, however old, must still transition it.
  def not_backfill?
    @store.packing_enabled_at.present? &&
      @order.ordered_at.present? &&
      @order.ordered_at >= @store.packing_enabled_at
  end

  def refund(package)
    package.refund! unless package.refunded?
  end

  # Existence re-check, number assignment, and package+items creation all
  # happen inside a single row lock so concurrent syncs of the SAME order
  # serialize: the second process, after acquiring the lock, sees the
  # package the first created and bails WITHOUT consuming a sequence number
  # (continuous, no gaps).
  def build_package
    @store.with_lock do
      return if @store.packages.exists?(order_id: @order.id)

      seq = @store.package_number_seq || @store.package_number_start
      @store.update!(package_number_seq: seq + 1)
      package = @store.packages.create!(
        order: @order,
        number: seq,
        shipping_address_snapshot: @order.shopify_data["shipping_address"] || {}
      )
      refunds = refunded_quantities # { shopify_line_item_id => qty }
      @order.order_line_items.includes(:product_variant).find_each do |li|
        package.package_items.create!(
          customs_attributes_for(li).merge(
            product_variant_id: li.product_variant_id,
            order_line_item_id: li.id,
            sku: li.sku_at_sale,
            title: li.title_at_sale,
            quantity: li.quantity,
            refunded_quantity: refunds[li.shopify_line_item_id] || 0
          )
        )
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # A concurrent sync already built it; safe to ignore. The order_id unique
    # index was dropped — the only unique index this can still trip is
    # shopify_store_id + number, which the @store.with_lock above already
    # serializes against.
    nil
  end

  # Re-sync an existing, non-terminal package's snapshots from the latest order
  # data, honoring per-section override flags (2B-2's edits set them). Item
  # refunds are marked, never deleted.
  def smart_update(package)
    package.with_lock do
      unless package.address_overridden
        package.update!(shipping_address_snapshot: @order.shopify_data["shipping_address"] || {})
      end
      sync_items(package)
    end
  end

  def sync_items(package)
    refunds = refunded_quantities
    existing_by_li = package.package_items.index_by(&:order_line_item_id)

    @order.order_line_items.includes(:product_variant).find_each do |li|
      item = existing_by_li[li.id]
      refunded = refunds[li.shopify_line_item_id] || 0
      if item
        attrs = { quantity: li.quantity, refunded_quantity: refunded }
        attrs.merge!(customs_attributes_for(li)) unless item.customs_overridden
        item.update!(attrs)
      else
        package.package_items.create!(
          customs_attributes_for(li).merge(
            product_variant_id: li.product_variant_id,
            order_line_item_id: li.id,
            sku: li.sku_at_sale,
            title: li.title_at_sale,
            quantity: li.quantity,
            refunded_quantity: refunded
          )
        )
      end
    end
  end

  # Customs snapshot copied from the line item's product_variant (nil-safe).
  def customs_attributes_for(line_item)
    v = line_item.product_variant
    return {} unless v

    {
      customs_name_zh: v.customs_name_zh,
      customs_name_en: v.customs_name_en,
      declared_value_usd: v.declared_value_usd,
      hs_code: v.hs_code,
      import_hs_code: v.import_hs_code,
      customs_weight_grams: v.weight_grams
    }
  end

  # Sum of refunded/cancelled units per shopify_line_item_id, from the order's
  # Shopify payload. { shopify_line_item_id (Integer) => refunded_qty (Integer) }
  def refunded_quantities
    result = Hash.new(0)
    Array(@order.shopify_data["refunds"]).each do |refund|
      next unless refund.is_a?(Hash)

      Array(refund["refund_line_items"]).each do |rli|
        next unless rli.is_a?(Hash)

        lid = Integer(rli["line_item_id"], exception: false)
        next unless lid

        result[lid] += rli["quantity"].to_i
      end
    end
    result
  end
end
