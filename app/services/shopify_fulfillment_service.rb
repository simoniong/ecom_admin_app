# Creates ONE Shopify fulfillment for a single package's line items (split
# orders → one fulfillment per package), carrying its tracking number, and
# notifying the customer. Reconciles first (a prior ambiguous create that
# timed out): if a fulfillment already carries this package's tracking number,
# adopt its id instead of re-creating. Line item ids are normalized (stored REST
# numeric id → GID) before matching Shopify's GID-based fulfillmentOrderLineItems.
# See docs/superpowers/specs/2026-07-22-order-packing-phase2e-shipped-design.md.
class ShopifyFulfillmentService
  class Error < StandardError; end

  API_VERSION = "2024-10"

  def initialize(package)
    @package = package
    @store = package.shopify_store
    @order = package.order
  end

  def call
    raise Error, "store is missing the fulfillment write scope — reauthorize" unless @store.fulfillment_write_scope?

    existing = reconcile_existing
    return existing if existing

    groups = open_fulfillment_order_line_item_groups
    raise Error, "no open fulfillment order for this order" if groups.empty?

    create_fulfillment(groups)
  end

  private

  def client
    @client ||= begin
      session = ShopifyAPI::Auth::Session.new(shop: @store.shop_domain, access_token: @store.access_token)
      ShopifyAPI::Clients::Graphql::Admin.new(session: session)
    end
  end

  def order_gid
    "gid://shopify/Order/#{@order.shopify_order_id}"
  end

  # Map this package's shippable items' REST line item ids to GIDs.
  def wanted_line_item_gids
    @package.shippable_items.each_with_object({}) do |item, h|
      next if item.order_line_item&.shopify_line_item_id.blank?

      qty = item.quantity - item.refunded_quantity
      next if qty <= 0

      h["gid://shopify/LineItem/#{item.order_line_item.shopify_line_item_id}"] = qty
    end
  end

  # Reconcile: has a fulfillment with this package's tracking number already been created?
  def reconcile_existing
    q = <<~GQL
      query($id: ID!) {
        order(id: $id) {
          fulfillments(first: 30) { id trackingInfo { number } }
        }
      }
    GQL
    data = run(q, id: order_gid).dig("order", "fulfillments") || []
    hit = data.find { |f| Array(f["trackingInfo"]).any? { |t| t["number"] == @package.tracking_number } }
    hit && hit["id"]
  end

  # Iterates ALL open fulfillment orders for this order and accumulates one
  # group per fulfillment order that carries any wanted line item (quantity =
  # min(remaining wanted, remainingQuantity)). A package's shippable items can
  # legitimately span multiple fulfillment orders (e.g. partially fulfilled
  # order, or Shopify splitting locations) — fulfilling only the first match
  # would silently under-ship the rest. Raises unless every wanted line item
  # is matched for its FULL wanted quantity across the accumulated groups.
  def open_fulfillment_order_line_item_groups
    q = <<~GQL
      query($id: ID!) {
        order(id: $id) {
          fulfillmentOrders(first: 20, query: "status:open") {
            edges { node { id status
              lineItems(first: 50) { edges { node { id remainingQuantity lineItem { id } } } } } }
          }
        }
      }
    GQL
    wanted = wanted_line_item_gids
    matched = Hash.new(0)
    groups = []

    (run(q, id: order_gid).dig("order", "fulfillmentOrders", "edges") || []).each do |edge|
      node = edge["node"]
      lines = (node.dig("lineItems", "edges") || []).filter_map do |le|
        n = le["node"]
        gid = n.dig("lineItem", "id")
        next unless wanted.key?(gid)

        remaining_wanted = wanted[gid] - matched[gid]
        next if remaining_wanted <= 0

        qty = [ remaining_wanted, n["remainingQuantity"].to_i ].min
        next if qty <= 0

        matched[gid] += qty
        { id: n["id"], quantity: qty }
      end
      groups << { fulfillment_order_id: node["id"], line_items: lines } if lines.any?
    end

    unmatched = wanted.any? { |gid, qty| matched[gid] < qty }
    # Only distinguish "partially matched across the open fulfillment orders
    # we did find" from "no open fulfillment order at all" — the latter is
    # raised by #call with a clearer message once it sees an empty groups list.
    raise Error, "could not fulfill all line items" if unmatched && groups.any?

    groups
  end

  def create_fulfillment(groups)
    m = <<~GQL
      mutation fulfillmentCreate($fulfillment: FulfillmentInput!) {
        fulfillmentCreate(fulfillment: $fulfillment) {
          fulfillment { id }
          userErrors { field message }
        }
      }
    GQL
    vars = {
      fulfillment: {
        lineItemsByFulfillmentOrder: groups.map { |g| { fulfillmentOrderId: g[:fulfillment_order_id], fulfillmentOrderLineItems: g[:line_items] } },
        trackingInfo: { number: @package.tracking_number, company: @package.logistics_channel&.shopify_carrier_name, url: tracking_url },
        notifyCustomer: true
      }
    }
    res = run(m, **vars)["fulfillmentCreate"] || {}
    errors = res["userErrors"] || []
    raise Error, errors.map { |e| e["message"] }.join("; ").presence || "fulfillmentCreate failed" if errors.any?

    res.dig("fulfillment", "id") or raise Error, "fulfillmentCreate returned no id"
  end

  def tracking_url
    @package.logistics_channel&.tracking_url_template.to_s.gsub("#TrackingNumber#", @package.tracking_number.to_s)
  end

  # Runs a GraphQL op; returns response.body["data"] (Hash). Raises Error on
  # transport failure or top-level GraphQL errors (message-only, safe).
  def run(query, **variables)
    resp = client.query(query: query, variables: variables)
    body = resp.body || {}
    if (errors = body["errors"] || []).any?
      # GraphQL's top-level error "message" is Shopify's own text (e.g. scope
      # or field errors) — safe to surface, and often the only clue that the
      # store is missing a required read/write scope.
      raise Error, "shopify graphql error: #{errors.map { |e| e['message'] }.join('; ')}"
    end

    body["data"] || {}
  rescue Error
    raise
  rescue ShopifyAPI::Errors::HttpResponseError => e
    raise Error, "shopify http error (#{e.code})"
  rescue => e
    raise Error, "shopify request failed (#{e.class})"
  end
end
