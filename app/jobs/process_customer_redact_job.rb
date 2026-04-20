class ProcessCustomerRedactJob < ApplicationJob
  queue_as :default

  def perform(shopify_store_id, payload)
    store = ShopifyStore.find_by(id: shopify_store_id)
    return unless store

    customer_data = payload["customer"] || {}
    shopify_customer_id = customer_data["id"]
    email = customer_data["email"]

    scope = store.customers
    scope = if shopify_customer_id.present?
      scope.where(shopify_customer_id: shopify_customer_id.to_s)
    elsif email.present?
      scope.where(email: email)
    else
      Rails.logger.warn("[ProcessCustomerRedact] store_id=#{shopify_store_id} missing customer identifiers")
      return
    end

    scope.find_each do |customer|
      Ticket.where(customer_id: customer.id).update_all(customer_id: nil)
      customer.destroy
    end
  rescue => e
    Rails.logger.error("[ProcessCustomerRedact] store_id=#{shopify_store_id}: #{e.message}")
  end
end
