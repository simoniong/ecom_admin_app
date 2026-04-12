class TicketsController < AdminController
  before_action :set_ticket, only: [ :show, :update, :search_customers, :link_customer ]

  def index
    tickets = Ticket.for_company(current_company).includes(:email_account, :customer)

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
  end

  def search_customers
    query = params[:q].to_s.strip
    results = []

    if query.length >= 2
      stores = current_company.shopify_stores
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

  def link_customer
    customer_id = params[:customer_id]
    stores = current_company.shopify_stores
    customer = Customer.where(shopify_store: stores).find(customer_id)

    @ticket.update!(customer: customer, customer_name: customer.full_name, customer_email: customer.email)

    redirect_to ticket_path(id: @ticket.id), notice: t("tickets.show.customer_linked")
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
      Ticket.for_company(current_company).reorder_positions!(params.dig(:ticket, :position_ids))
    end

    respond_to do |format|
      format.json { render json: { status: @ticket.status }, status: :ok }
      format.html { redirect_to tickets_path, notice: t("tickets.status_updated") }
    end
  rescue Ticket::InvalidTransition => e
    respond_to do |format|
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
      format.html { redirect_to tickets_path, alert: t("tickets.invalid_transition") }
    end
  end

  def handle_reorder
    Ticket.for_company(current_company).reorder_positions!(params.dig(:ticket, :position_ids))

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
      render :show, status: :unprocessable_entity
    end
  end

  def set_ticket
    @ticket = Ticket.for_company(current_company).includes(customer: { orders: :fulfillments }).find(params[:id])
  end

  def ticket_params
    params.require(:ticket).permit(:draft_reply, :status)
  end
end
