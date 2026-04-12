class Api::V1::TicketsController < Api::BaseController
  def index
    tickets = Ticket.by_recency
    tickets = tickets.where(status: resolved_status) if valid_status?

    render json: tickets.map { |t| ticket_json(t) }
  end

  def count
    tickets = Ticket.all
    tickets = tickets.where(status: resolved_status) if valid_status?

    render json: { count: tickets.count }
  end

  def show
    ticket = Ticket.includes(:messages, customer: { orders: :fulfillments })
                   .find(params[:id])
    render json: ticket_json(ticket, detail: true)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Ticket not found" }, status: :not_found
  end

  def draft_reply
    ticket = Ticket.find(params[:id])

    unless ticket.new_ticket? || ticket.draft?
      return render json: { error: "Ticket is not in new or draft status" }, status: :unprocessable_entity
    end

    content = params[:draft_reply]
    if content.blank?
      return render json: { error: "Draft reply content is required" }, status: :unprocessable_entity
    end

    if ticket.new_ticket?
      ticket.submit_draft!(content)
    else
      ticket.update!(draft_reply: content, draft_reply_at: Time.current)
    end

    render json: ticket_json(ticket), status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Ticket not found" }, status: :not_found
  rescue ActiveRecord::RecordInvalid
    render json: { error: "Validation failed", details: ticket.errors.full_messages }, status: :unprocessable_entity
  end

  private

  API_STATUS_MAP = {
    "new" => "new_ticket",
    "draft" => "draft",
    "draft_confirmed" => "draft_confirmed",
    "closed" => "closed"
  }.freeze

  def resolved_status
    API_STATUS_MAP[params[:status]]
  end

  def valid_status?
    params[:status].present? && resolved_status.present?
  end

  def api_status(ticket)
    ticket.new_ticket? ? "new" : ticket.status
  end

  def ticket_json(ticket, detail: false)
    json = {
      id: ticket.id,
      subject: ticket.subject,
      status: api_status(ticket),
      customer_email: ticket.customer_email,
      customer_name: ticket.customer_name,
      draft_reply: ticket.draft_reply,
      draft_reply_at: ticket.draft_reply_at,
      last_message_at: ticket.last_message_at,
      created_at: ticket.created_at
    }

    if detail
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
              transit_days: f.transit_days,
              tracking_events: f.tracking_events.map do |e|
                {
                  description: e["description"],
                  time: e["time"],
                  location: e["location"]
                }
              end
            }
          end
        }
      end
    end

    json
  end
end
