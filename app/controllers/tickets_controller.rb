class TicketsController < AdminController
  before_action :set_ticket, only: [ :show, :update ]

  def index
    tickets = Ticket.for_user(current_user).includes(:email_account).by_position.to_a
    grouped = tickets.group_by(&:status)
    @tickets_by_status = Ticket.statuses.keys.index_with do |status|
      grouped[status] || []
    end
  end

  def show
    @messages = @ticket.messages.order(sent_at: :desc)
    @customer = @ticket.customer
    @orders = @customer&.orders&.by_recency || []
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
      Ticket.for_user(current_user).reorder_positions!(params.dig(:ticket, :position_ids))
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
    Ticket.for_user(current_user).reorder_positions!(params.dig(:ticket, :position_ids))

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
      render :show, status: :unprocessable_entity
    end
  end

  def set_ticket
    @ticket = Ticket.for_user(current_user).includes(customer: { orders: :fulfillments }).find(params[:id])
  end

  def ticket_params
    params.require(:ticket).permit(:draft_reply, :status)
  end
end
