class TicketsController < AdminController
  def index
    @tickets = Ticket.for_user(current_user).includes(:email_account).by_recency
    @tickets = @tickets.where(status: params[:status]) if params[:status].present?
  end

  def show
    @ticket = Ticket.for_user(current_user).find(params[:id])
    @messages = @ticket.messages.chronological
  end
end
