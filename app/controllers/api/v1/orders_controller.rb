class Api::V1::OrdersController < Api::CompanyBaseController
  def shipping
    order = Order.where(shopify_store_id: company_stores.select(:id))
                 .includes(:parcels)
                 .find_by!(name: params[:name])

    render json: {
      order_name: order.name,
      currency: order.currency,
      estimated_shipping_cost: order.estimated_shipping_cost,
      actual_shipping_cost: order.actual_shipping_cost,
      variance: order.shipping_variance,
      variance_pct: order.shipping_variance_pct,
      parcel_count: order.parcels.size,
      parcels: order.parcels.map do |p|
        {
          identifier: p.identifier,
          tracking_number: p.tracking_number,
          service_channel: p.service_channel,
          billed_weight_g: p.billed_weight_g,
          cost_cny: p.cost_cny,
          registration_fee_cny: p.registration_fee_cny,
          operation_fee_cny: p.operation_fee_cny,
          cost_amount: p.cost_amount
        }
      end
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Order not found" }, status: :not_found
  end
end
