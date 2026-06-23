class TicketsController < AdminController
  before_action :set_ticket, only: [ :show, :update, :search_customers, :search_orders, :link_customer, :instruct_agent, :bind_order ]

  def index
    tickets = visible_tickets.includes(:email_account, :customer)

    search_query = params[:q].to_s
    if search_query.present?
      query = "%#{Ticket.sanitize_sql_like(search_query)}%"
      tickets = tickets
        .left_joins(customer: :orders)
        .where(
          "tickets.subject ILIKE :q OR tickets.customer_name ILIKE :q OR orders.name ILIKE :q",
          q: query
        )
        .distinct
    end

    tickets = tickets.by_position.to_a
    grouped = tickets.group_by(&:status)
    @tickets_by_status = Ticket.statuses.keys.index_with do |status|
      grouped[status] || []
    end
  end

  def show
    @messages = @ticket.messages.order(sent_at: :desc)
    @customer = @ticket.customer
    @orders = @customer&.orders&.by_recency || []
    @ticket_timezone = @ticket.email_account&.shopify_store&.active_timezone || store_timezone
    @customer_threads = @ticket.customer_threads
  end

  def search_customers
    query = params[:q].to_s.strip
    results = []

    if query.length >= 2
      stores = ticket_store_scope
      customers = Customer.where(shopify_store: stores)
        .left_joins(:orders)
        .where(
          "customers.email ILIKE :q OR customers.first_name ILIKE :q OR customers.last_name ILIKE :q OR CONCAT(customers.first_name, ' ', customers.last_name) ILIKE :q",
          q: "%#{Customer.sanitize_sql_like(query)}%"
        )
        .group("customers.id")
        .select("customers.*, COUNT(orders.id) AS orders_count")
        .limit(10)

      orders = Order.where(shopify_store: stores)
        .where("orders.name ILIKE :q", q: "%#{Order.sanitize_sql_like(query)}%")
        .includes(:customer)
        .limit(10)

      seen_customer_ids = {}

      customers.each do |c|
        seen_customer_ids[c.id] = true
        results << {
          customer_id: c.id,
          customer_name: c.full_name,
          customer_email: c.email,
          match_type: "customer",
          order_count: c.orders_count
        }
      end

      orders.each do |o|
        next if seen_customer_ids.key?(o.customer_id)
        seen_customer_ids[o.customer_id] = true
        results << {
          customer_id: o.customer_id,
          customer_name: o.customer.full_name,
          customer_email: o.customer.email,
          match_type: "order",
          order_name: o.name
        }
      end
    end

    render json: results
  end

  def search_orders
    query = params[:q].to_s.strip
    stores = ticket_store_scope

    orders =
      if query.present?
        Order.where(shopify_store: stores).search_by(query).includes(:customer).limit(20)
      elsif @ticket.customer_id.present?
        @ticket.customer.orders.by_recency.includes(:customer).limit(20)
      else
        Order.none
      end

    render json: orders.map { |o|
      {
        id: o.id,
        name: o.name,
        customer_name: o.customer&.full_name,
        total: o.total_price,
        fulfillment_status: o.fulfillment_status
      }
    }
  end

  def link_customer
    customer_id = params[:customer_id]
    stores = ticket_store_scope
    customer = Customer.where(shopify_store: stores).find(customer_id)

    @ticket.update!(customer: customer, customer_name: customer.full_name, customer_email: customer.email)

    redirect_to ticket_path(id: @ticket.id), notice: t("tickets.show.customer_linked")
  end

  def bind_order
    if params[:order_id].blank?
      @ticket.update!(order: nil)
      return redirect_to ticket_path(id: @ticket.id), notice: t("tickets.show.order_unbound")
    end

    order = Order.where(shopify_store: ticket_store_scope).find(params[:order_id])

    if @ticket.customer_id.present? && order.customer_id != @ticket.customer_id
      return redirect_to ticket_path(id: @ticket.id), alert: t("tickets.show.order_customer_mismatch")
    end

    attrs = { order: order }
    if @ticket.customer_id.nil?
      attrs[:customer] = order.customer
      attrs[:customer_email] = order.customer.email
      attrs[:customer_name] = order.customer.full_name
    end
    @ticket.update!(attrs)

    redirect_to ticket_path(id: @ticket.id), notice: t("tickets.show.order_bound")
  end

  def instruct_agent
    unless @ticket.new_ticket? || @ticket.draft?
      redirect_to ticket_path(id: @ticket.id), alert: t("tickets.agent_instruction_not_allowed")
      return
    end

    message = params[:message].to_s.strip
    if message.blank?
      redirect_to ticket_path(id: @ticket.id), alert: t("tickets.agent_instruction_blank")
      return
    end

    NotifyAgentJob.perform_later(@ticket.id, "revise_draft", message)
    redirect_to ticket_path(id: @ticket.id), notice: t("tickets.show.instruction_sent")
  end

  def create
    # Fix 3: require a subject server-side
    return redirect_to(tickets_path, alert: t("tickets.create_failed")) if params.dig(:ticket, :subject).blank?

    email_account = visible_email_accounts.find_by(id: params.dig(:ticket, :email_account_id))
    return redirect_to(tickets_path, alert: t("tickets.create_failed")) if email_account.nil?

    # A ticket belongs to its email account's store, so customer/order lookups
    # are scoped to that store (not all visible stores).
    stores = store_scope_for(email_account)

    ticket = email_account.tickets.new(new_thread_params)
    ticket.assign_attributes(initiated_by: :agent, status: :draft,
                             draft_reply_at: Time.current, gmail_thread_id: nil)

    customer = nil
    if (customer_id = params.dig(:ticket, :customer_id)).present?
      customer = Customer.where(shopify_store: stores).find_by(id: customer_id)
      return redirect_to(tickets_path, alert: t("tickets.create_failed")) if customer.nil?
    end

    order = nil
    if (order_id = params.dig(:ticket, :order_id)).present?
      order = Order.where(shopify_store: stores).find_by(id: order_id)
      return redirect_to(tickets_path, alert: t("tickets.create_failed")) if order.nil?
    end

    # Fix 1: cross-customer order guard + reverse-link (mirrors bind_order)
    if customer.present? && order.present? && order.customer_id != customer.id
      return redirect_to(tickets_path, alert: t("tickets.create_failed"))
    end

    if order.present? && customer.nil?
      # Fix 1: reverse-link — derive customer from the order
      customer = order.customer
    end

    ticket.order = order if order.present?
    ticket.customer = customer if customer.present?

    # Fix 2: overwrite email/name from the resolved customer (ignores tampered params)
    if customer.present?
      ticket.customer_email = customer.email
      ticket.customer_name = customer.full_name
    end

    if ticket.save
      redirect_to ticket_path(id: ticket.id), notice: t("tickets.show.thread_created")
    else
      redirect_to tickets_path, alert: ticket.errors.full_messages.join(", ")
    end
  end

  def update
    if params.dig(:ticket, :status).present?
      handle_status_transition
    elsif params.dig(:ticket, :position_ids).present?
      handle_reorder
    else
      handle_draft_update
    end
  end

  private

  def handle_status_transition
    @ticket.transition_status!(params.dig(:ticket, :status))

    if params.dig(:ticket, :position_ids).present?
      visible_tickets.reorder_positions!(params.dig(:ticket, :position_ids))
    end

    respond_to do |format|
      format.json { render json: { status: @ticket.status }, status: :ok }
      format.html { redirect_to ticket_path(id: @ticket.id), notice: t("tickets.status_updated") }
    end
  rescue Ticket::InvalidTransition => e
    respond_to do |format|
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
      format.html { redirect_to ticket_path(id: @ticket.id), alert: t("tickets.invalid_transition") }
    end
  rescue ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.json { render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity }
      format.html { redirect_to ticket_path(id: @ticket.id), alert: e.record.errors.full_messages.join(", ") }
    end
  end

  def handle_reorder
    visible_tickets.reorder_positions!(params.dig(:ticket, :position_ids))

    respond_to do |format|
      format.json { render json: { success: true }, status: :ok }
      format.html { redirect_to tickets_path }
    end
  end

  def handle_draft_update
    unless @ticket.new_ticket? || @ticket.draft?
      redirect_to ticket_path(id: @ticket.id), alert: t("tickets.draft_not_editable")
      return
    end

    if @ticket.update(ticket_params)
      redirect_to ticket_path(id: @ticket.id), notice: t("tickets.show.draft_saved")
    else
      @messages = @ticket.messages.order(sent_at: :desc)
      @customer = @ticket.customer
      @orders = @customer&.orders&.by_recency || []
      @ticket_timezone = @ticket.email_account&.shopify_store&.active_timezone || store_timezone
      @customer_threads = @ticket.customer_threads
      render :show, status: :unprocessable_entity
    end
  end

  def set_ticket
    @ticket = visible_tickets.includes(customer: { orders: :fulfillments }).find(params[:id])
  end

  # Stores a ticket's customer/order lookups may search: the ticket's own store
  # only. Falls back to all visible stores when the email account has no store
  # association (legacy/orphaned accounts), so linking still works there.
  def ticket_store_scope
    store_scope_for(@ticket.email_account)
  end

  def store_scope_for(email_account)
    store_id = email_account&.shopify_store_id
    store_id ? ShopifyStore.where(id: store_id) : visible_shopify_stores
  end

  def ticket_params
    params.require(:ticket).permit(:draft_reply, :status)
  end

  def new_thread_params
    params.require(:ticket).permit(:customer_email, :customer_name, :subject, :draft_reply)
  end
end
