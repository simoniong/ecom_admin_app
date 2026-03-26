class TicketsController < AdminController
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
    @ticket = Ticket.for_user(current_user).includes(customer: { orders: :fulfillments }).find(params[:id])
    @messages = @ticket.messages.order(sent_at: :desc)
    @customer = @ticket.customer
    @orders = @customer&.orders&.by_recency || []
  end
end
