class TicketsController < AdminController
  def index
    @status = params[:status] || "new_ticket"
    @tickets = Ticket.for_user(current_user).includes(:email_account).by_recency
    @tickets = @tickets.where(status: @status) unless @status == "all"
  end

  def show
    @ticket = Ticket.for_user(current_user).find(params[:id])
    @messages = @ticket.messages.chronological
  end
end
