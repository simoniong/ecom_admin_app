# Folds a pending_process package into one or more new sibling packages
# (same order, new store sequence numbers). Only shippable units
# (quantity - refunded_quantity) move; refunded units stay on the source.
# See docs/superpowers/specs/2026-07-21-order-packing-phase2b3-split-merge-design.md.
class PackageSplitter
  Result = Struct.new(:success?, :source, :new_packages, :errors, keyword_init: true)

  # allocations: { order_line_item_id(String) => [units_for_new_box_1, ...] }
  def initialize(source, allocations)
    @source = source
    @store  = source.shopify_store
    @allocations = (allocations || {}).transform_values { |a| Array(a).map(&:to_i) }
  end

  def call
    errors = validate
    return failure(errors) if errors.any?

    new_packages = []
    @store.with_lock do
      box_count.times do |box_idx|
        pkg = build_box(box_idx)
        new_packages << pkg if pkg
      end
      apply_source_remainders
    end
    Result.new(success?: true, source: @source, new_packages: new_packages, errors: [])
  end

  private

  def failure(errors)
    Result.new(success?: false, source: @source, new_packages: [], errors: errors)
  end

  def source_items_by_li
    @source_items_by_li ||= @source.package_items.index_by { |it| it.order_line_item_id.to_s }
  end

  def box_count
    @box_count ||= @allocations.values.map(&:size).max.to_i
  end

  def shippable(item)
    item.quantity - item.refunded_quantity
  end

  def units_for(item, box_idx)
    (@allocations[item.order_line_item_id.to_s] || [])[box_idx].to_i
  end

  def moved_total(item)
    Array(@allocations[item.order_line_item_id.to_s]).sum
  end

  def validate
    return [ :empty ] if @allocations.empty? || box_count.zero?

    errors = []
    errors << :ragged if @allocations.values.any? { |a| a.size != box_count }
    errors << :unknown_item if @allocations.keys.any? { |k| source_items_by_li[k].nil? }
    errors << :negative if @allocations.values.flatten.any?(&:negative?)
    return errors.uniq if errors.any? # further checks assume well-formed input

    source_items_by_li.each_value do |item|
      errors << :over_allocated if moved_total(item) > shippable(item)
    end

    box_count.times do |box_idx|
      box_units = source_items_by_li.each_value.sum { |it| units_for(it, box_idx) }
      errors << :empty_box if box_units.zero?
    end

    source_remaining = source_items_by_li.each_value.sum { |it| shippable(it) - moved_total(it) }
    errors << :empty_source if source_remaining <= 0

    errors.uniq
  end

  def build_box(box_idx)
    items = source_items_by_li.each_value.select { |it| units_for(it, box_idx).positive? }
    return nil if items.empty?

    seq = @store.package_number_seq || @store.package_number_start
    @store.update!(package_number_seq: seq + 1)
    box = @store.packages.create!(
      order: @source.order,
      number: seq,
      aasm_state: "pending_process",
      shipping_address_snapshot: @source.shipping_address_snapshot,
      address_overridden: @source.address_overridden,
      logistics_channel_id: @source.logistics_channel_id
    )
    items.each do |it|
      box.package_items.create!(
        order_line_item_id: it.order_line_item_id,
        product_variant_id: it.product_variant_id,
        sku: it.sku,
        title: it.title,
        quantity: units_for(it, box_idx),
        refunded_quantity: 0,
        customs_name_zh: it.customs_name_zh,
        customs_name_en: it.customs_name_en,
        declared_value_usd: it.declared_value_usd,
        customs_weight_grams: it.customs_weight_grams,
        hs_code: it.hs_code,
        import_hs_code: it.import_hs_code,
        customs_overridden: it.customs_overridden
      )
    end
    box
  end

  def apply_source_remainders
    source_items_by_li.each_value do |item|
      moved = moved_total(item)
      next if moved.zero?

      new_qty = item.quantity - moved
      new_qty.zero? ? item.destroy! : item.update!(quantity: new_qty)
    end
  end
end
