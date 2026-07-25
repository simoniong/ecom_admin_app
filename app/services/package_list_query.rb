# Filtering + ordering for the packing list. The caller passes in an ALREADY
# authorized scope (company/store/state applied) — this object never widens it
# and knows nothing about permissions. Pagination stays in the controller.
class PackageListQuery
  # The list renders the package's own address snapshot and falls back to the
  # order's raw Shopify address when the snapshot has no country (see
  # _package_row.html.erb). Both the selectable-country list and the filter
  # itself must use this SAME expression — otherwise a row displaying 美國
  # would not come back when the user clicks 美國.
  #
  # NULLIF(TRIM(...), '') mirrors Order::DESTINATION_COUNTRY_SQL, this app's
  # existing way of reading a country code out of Shopify JSON, so a
  # whitespace-only value counts as absent in both places.
  #
  # UPPER is not paranoia: #update_address lets a human hand-edit the snapshot
  # (ADDRESS_KEYS includes country_code) with no normalization, so a lowercase
  # "us" really can land in the column and would otherwise split one country
  # into two pills.
  COUNTRY_SQL = <<~SQL.squish
    COALESCE(
      UPPER(NULLIF(TRIM(packages.shipping_address_snapshot->>'country_code'), '')),
      UPPER(NULLIF(TRIM(orders.shopify_data #>> '{shipping_address,country_code}'), ''))
    )
  SQL

  # Insertion order drives the order of the sort controls in the filter bar.
  SORT_COLUMNS = {
    "created_at" => "packages.created_at",
    "ordered_at" => "orders.ordered_at",
    "paid_at"    => "orders.paid_at"
  }.freeze
  DEFAULT_SORT_COLUMN = "created_at"

  attr_reader :sort_column, :sort_direction

  def initialize(scope, country: nil, sort_column: nil, sort_direction: nil)
    # packages.order is a required belongs_to, so this inner join never drops a
    # row — joining unconditionally keeps the SQL identical whether or not the
    # country filter and order-based sorts are in play.
    @scope = scope.joins(:order)
    @requested_country = country.to_s.upcase.presence
    @sort_column = SORT_COLUMNS.key?(sort_column) ? sort_column : DEFAULT_SORT_COLUMN
    @sort_direction = sort_direction == "asc" ? "asc" : "desc"
  end

  # Country codes that actually occur in this scope. Sorting is left to the
  # view, which orders by the localized country name — not something SQL can do.
  def countries
    @countries ||= @scope.reorder(nil).distinct.pluck(Arel.sql(COUNTRY_SQL)).compact_blank
  end

  # Only a country actually present in this scope is honoured; anything else
  # (unknown code, blank, junk) falls through to "all" rather than 404ing or
  # showing an empty list the user can't explain.
  def country
    return @country if defined?(@country)

    @country = countries.include?(@requested_country) ? @requested_country : nil
  end

  def relation
    rel = @scope
    rel = rel.where("#{COUNTRY_SQL} = ?", country) if country
    rel.reorder(Arel.sql(order_sql))
  end

  private

  # NULLS LAST in BOTH directions: ordered_at/paid_at are nullable, and an
  # ascending sort would otherwise open on a page of blanks. packages.id is the
  # tie-breaker — without one, rows sharing a timestamp can repeat or vanish
  # across page boundaries.
  #
  # Both interpolated values come from the constant tables above (never from
  # user input), so this string can never carry an injection.
  def order_sql
    "#{SORT_COLUMNS.fetch(sort_column)} #{sort_direction} NULLS LAST, packages.id #{sort_direction}"
  end
end
