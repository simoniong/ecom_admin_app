# Fills in order_name for parsed bill rows that carry no Shopify order name but
# do carry the package_code our packing module sent to the carrier (the
# 哆啦任意门 bill's 客户订单号). Once order_name is set, everything downstream —
# the import preview's matched/unmatched counts and ParcelUpserter's order
# lookup — works unchanged for both bill shapes.
#
# Lookup order, all scoped to the importing store:
#   1. package_code = store.package_prefix + number (Package#package_code)
#   2. the package's tracking_number against the row's waybill (internal_no)
#      or last-mile number (tracking_number) — covers a prefix that doesn't
#      match the store's, e.g. a package code issued before a prefix change
# A row that matches neither is left with order_name nil, and the preview
# lists it as unmatched for the operator to assign by hand.
class PackageOrderResolver
  def initialize(store)
    @store = store
  end

  # Returns new row hashes; rows that already have an order_name, or have no
  # package_code, are returned untouched.
  def call(rows)
    pending = rows.select { |r| resolvable?(r) }
    return rows if pending.empty?

    by_number = orders_by_package_number(pending)
    by_tracking = orders_by_tracking(pending)

    rows.map do |row|
      next row unless resolvable?(row)

      name = by_number[package_number(row[:package_code])] ||
             by_tracking[row[:internal_no]] ||
             by_tracking[row[:tracking_number]]
      name ? row.merge(order_name: name) : row
    end
  end

  private

  def resolvable?(row)
    row[:order_name].blank? && row[:package_code].present?
  end

  def orders_by_package_number(rows)
    numbers = rows.filter_map { |r| package_number(r[:package_code]) }.uniq
    return {} if numbers.empty?

    @store.packages.joins(:order).where(number: numbers).pluck(:number, "orders.name").to_h
  end

  def orders_by_tracking(rows)
    candidates = rows.flat_map { |r| [ r[:internal_no], r[:tracking_number] ] }.compact_blank.uniq
    return {} if candidates.empty?

    @store.packages.joins(:order).where(tracking_number: candidates)
          .pluck(:tracking_number, "orders.name").to_h
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
