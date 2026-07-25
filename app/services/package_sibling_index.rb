# Box numbering ("box 2 of 3") for split orders, resolved for a whole page of
# packages in one query. Package#split? is a COUNT per package — fine inside a
# single modal, an N+1 across a 50-row list.
#
# Contract: #call issues exactly ONE query of its own — the pluck below —
# on top of however the caller already materialized @packages. Pass it an
# Array (or an already-loaded Relation) and that's the only query you pay.
# Pass it an unloaded Relation and @packages.map { ... } forces it to
# load first, so the total becomes two queries: one to load the relation,
# one of this class's own. That's expected, not a regression — the callers
# that hand this class a Relation are rendering those same packages in the
# list anyway, so the load isn't wasted work.
#
# Store-scoped, matching Package#order_packages (`shopify_store.packages.
# where(order_id: ...)`). order_id alone is not a safe grouping key: nothing
# in the schema stops a Package row's shopify_store_id from disagreeing with
# its own order's real store (no writer creates that today, but nothing
# enforces it either), and a naive `where(order_id: order_ids)` would fold
# such a package into another store's order group — a stray "1/2" badge on a
# package Package#split? (itself store-scoped) says is not split at all.
# Each input package therefore contributes its own (order_id, store_id)
# pair, and boxes are grouped by that exact pair rather than by order_id
# alone.
class PackageSiblingIndex
  def initialize(packages)
    @packages = packages
  end

  # => { package_id => [ position, total ] }, containing ONLY packages whose
  # order is folded into more than one box. Callers render the badge when the
  # key is present, so no caller needs its own "is this split?" test.
  def call
    pairs = @packages.map { |package| [ package.order_id, package.shopify_store_id ] }.uniq
    return {} if pairs.empty?

    # One OR-of-ANDs query — still a single round trip — rather than
    # `where(order_id: ..., shopify_store_id: ...)`, which would cross-match
    # any order_id against any store_id in the two IN lists instead of
    # matching them pairwise.
    scope = pairs.map { |order_id, store_id| Package.where(order_id: order_id, shopify_store_id: store_id) }
                 .reduce { |combined, relation| combined.or(relation) }
    rows = scope.pluck(:order_id, :shopify_store_id, :id, :number)
    rows.group_by { |(order_id, store_id, _id, _number)| [ order_id, store_id ] }
        .each_with_object({}) do |(_key, boxes), map|
      next if boxes.size < 2

      # Sorted by box NUMBER, which is what the operator sees on screen and on
      # the carrier's label — not by id or creation order, which can disagree
      # with it once a package has been split, merged, and split again.
      boxes.sort_by { |(_o, _s, _id, number)| number }.each_with_index do |(_o, _s, id, _n), position|
        map[id] = [ position + 1, boxes.size ]
      end
    end
  end
end
