# Box numbering ("box 2 of 3") for split orders, resolved for a whole page of
# packages in one query. Package#split? is a COUNT per package — fine inside a
# single modal, an N+1 across a 50-row list.
class PackageSiblingIndex
  def initialize(packages)
    @packages = packages
  end

  # => { package_id => [ position, total ] }, containing ONLY packages whose
  # order is folded into more than one box. Callers render the badge when the
  # key is present, so no caller needs its own "is this split?" test.
  def call
    order_ids = @packages.map(&:order_id).uniq
    return {} if order_ids.empty?

    rows = Package.where(order_id: order_ids).pluck(:order_id, :id, :number)
    rows.group_by(&:first).each_with_object({}) do |(_order_id, boxes), map|
      next if boxes.size < 2

      # Sorted by box NUMBER, which is what the operator sees on screen and on
      # the carrier's label — not by id or creation order, which can disagree
      # with it once a package has been split, merged, and split again.
      boxes.sort_by { |(_o, _id, number)| number }.each_with_index do |(_o, id, _n), position|
        map[id] = [ position + 1, boxes.size ]
      end
    end
  end
end
