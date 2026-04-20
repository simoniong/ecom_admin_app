class ShopifyStoreDeletionService
  def initialize(store)
    @store = store
  end

  def call
    ActiveRecord::Base.transaction do
      @store.lock!

      customer_ids = @store.customers.select(:id)
      orders = Order.where(customer_id: customer_ids)
                    .or(Order.where(shopify_store_id: @store.id))

      order_ids = orders.select(:id)
      Fulfillment.where(order_id: order_ids).delete_all
      EmailWorkflowRun.where(order_id: order_ids).delete_all
      orders.delete_all
      Ticket.where(customer_id: customer_ids).update_all(customer_id: nil)
      Customer.where(id: customer_ids).delete_all
      @store.destroy!
    end
  end
end
