class TicketsController < AdminController
  before_action :set_ticket, only: [ :show, :update ]

  def index
    @status = params[:status] || "new_ticket"
    @tickets = Ticket.for_user(current_user).includes(:email_account).by_recency

    if @status != "all" && Ticket.statuses.key?(@status)
      @tickets = @tickets.where(status: @status)
    elsif @status != "all"
      @status = "new_ticket"
      @tickets = @tickets.where(status: :new_ticket)
    end
  end

  def show
    @messages = @ticket.messages.order(sent_at: :desc)
    @customer = @ticket.customer
    @orders = @customer&.orders&.by_recency || []
  end

  def update
    unless @ticket.draft?
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

  private

  def set_ticket
    @ticket = Ticket.for_user(current_user).includes(customer: { orders: :fulfillments }).find(params[:id])
  end

  def ticket_params
    params.require(:ticket).permit(:draft_reply)
  end
end
