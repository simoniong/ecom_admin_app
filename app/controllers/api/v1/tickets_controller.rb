class Api::V1::TicketsController < Api::BaseController
  def index
    tickets = Ticket.where(status: :new_ticket)
                    .includes(:messages, :email_account, :customer)
                    .by_recency

    render json: tickets.map { |t| ticket_json(t) }
  end

  def show
    ticket = Ticket.where(status: :new_ticket)
                   .includes(:messages, customer: { orders: :fulfillments })
                   .find(params[:id])
    render json: ticket_json(ticket, detail: true)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Ticket not found or not in new status" }, status: :not_found
  end

  def draft_reply
    ticket = Ticket.find(params[:id])

    unless ticket.new_ticket?
      return render json: { error: "Ticket is not in new status" }, status: :unprocessable_entity
    end

    content = params[:draft_reply]
    if content.blank?
      return render json: { error: "Draft reply content is required" }, status: :unprocessable_entity
    end

    ticket.submit_draft!(content)
    render json: ticket_json(ticket), status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Ticket not found" }, status: :not_found
  rescue ActiveRecord::RecordInvalid
    render json: { error: "Validation failed", details: ticket.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def ticket_json(ticket, detail: false)
    json = {
      id: ticket.id,
      subject: ticket.subject,
      status: ticket.status,
      customer_email: ticket.customer_email,
      customer_name: ticket.customer_name,
      draft_reply: ticket.draft_reply,
      draft_reply_at: ticket.draft_reply_at,
      last_message_at: ticket.last_message_at,
      created_at: ticket.created_at
    }

    json[:messages] = ticket.messages.sort_by { |m| m.sent_at || Time.at(0) }.reverse.map do |m|
      {
        id: m.id,
        from: m.from,
        to: m.to,
        subject: m.subject,
        body: m.body,
        sent_at: m.sent_at
      }
    end

    if detail && ticket.customer
      json[:customer] = {
        id: ticket.customer.id,
        email: ticket.customer.email,
        first_name: ticket.customer.first_name,
        last_name: ticket.customer.last_name,
        phone: ticket.customer.phone
      }

      json[:orders] = ticket.customer.orders.sort_by { |o| o.ordered_at || Time.at(0) }.reverse.map do |order|
        {
          id: order.id,
          name: order.name,
          total_price: order.total_price,
          currency: order.currency,
          financial_status: order.financial_status,
          fulfillment_status: order.fulfillment_status,
          ordered_at: order.ordered_at,
          fulfillments: order.fulfillments.map do |f|
            {
              id: f.id,
              status: f.status,
              tracking_number: f.tracking_number,
              tracking_company: f.tracking_company,
              tracking_url: f.tracking_url,
              tracking_status: f.tracking_status,
              tracking_sub_status: f.tracking_sub_status,
              origin_country: f.origin_country,
              destination_country: f.destination_country,
              shipped_at: f.shipped_at,
              shopify_shipped_at: f.shopify_shipped_at,
              delivered_at: f.delivered_at,
              last_event_at: f.last_event_at,
              latest_event_description: f.latest_event_description,
              transit_days: f.transit_days
            }
          end
        }
      end
    end

    json
  end
end
