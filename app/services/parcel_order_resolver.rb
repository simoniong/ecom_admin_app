# Fills in order_name for parsed bill rows that carry no Shopify order name —
# the 哆啦任意门 bill names our ERP's package code (客户订单号) instead. Once
# order_name is set, everything downstream — the import preview's
# matched/unmatched counts and ParcelUpserter's order lookup — works unchanged
# for both bill shapes.
#
# Lookup order, all scoped to the importing store:
#   1. Shopify fulfillment tracking number against the row's waybill
#      (internal_no, the DOR…CN number) or last-mile number (tracking_number).
#      The ERP writes the waybill back to Shopify when it ships, so this is
#      what matches in practice — the October bill matched 129 of 133 this way;
#      the rest were reships (…R1) whose numbers never reach Shopify.
#   2. A Package created by our own packing module, by package_code
#      (store.package_prefix + number) or by its tracking number. Unused while
#      the ERP lives outside this app, kept for when packing moves in here.
# A row that matches nothing keeps order_name nil, and the preview lists it as
# unmatched for the operator to assign by hand.
class ParcelOrderResolver
  def initialize(store)
    @store = store
  end

  # Returns new row hashes; rows that already have an order_name, or carry no
  # package_code (i.e. aren't from a bill that needs resolving), are returned
  # untouched.
  def call(rows)
    pending = rows.select { |r| resolvable?(r) }
    return rows if pending.empty?

    numbers = pending.flat_map { |r| [ r[:internal_no], r[:tracking_number] ] }.compact_blank.uniq
    by_fulfillment = orders_by_fulfillment_tracking(numbers)
    by_package_tracking = orders_by_package_tracking(numbers)
    by_package_number = orders_by_package_number(pending)

    rows.map do |row|
      next row unless resolvable?(row)

      name = by_fulfillment[row[:internal_no]] ||
             by_fulfillment[row[:tracking_number]] ||
             by_package_number[package_number(row[:package_code])] ||
             by_package_tracking[row[:internal_no]] ||
             by_package_tracking[row[:tracking_number]]
      name ? row.merge(order_name: name) : row
    end
  end

  private

  def resolvable?(row)
    row[:order_name].blank? && row[:package_code].present?
  end

  def orders_by_fulfillment_tracking(numbers)
    return {} if numbers.empty?

    Fulfillment.joins(:order)
               .where(orders: { shopify_store_id: @store.id }, tracking_number: numbers)
               .pluck(:tracking_number, "orders.name").to_h
  end

  def orders_by_package_tracking(numbers)
    return {} if numbers.empty?

    @store.packages.joins(:order).where(tracking_number: numbers)
          .pluck(:tracking_number, "orders.name").to_h
  end

  def orders_by_package_number(rows)
    numbers = rows.filter_map { |r| package_number(r[:package_code]) }.uniq
    return {} if numbers.empty?

    @store.packages.joins(:order).where(number: numbers).pluck(:number, "orders.name").to_h
  end

  # "XMBDP1004342" → 1004342, only when the prefix is this store's. Any other
  # prefix returns nil so a different store's package with the same number can
  # never be matched.
  def package_number(code)
    prefix = @store.package_prefix
    return nil if prefix.blank? || code.blank?

    rest = code.to_s.strip.delete_prefix(prefix)
    return nil if rest == code.to_s.strip || rest !~ /\A\d+\z/

    rest.to_i
  end
end
