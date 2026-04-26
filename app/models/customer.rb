class Customer < ApplicationRecord
  belongs_to :shopify_store, optional: true
  has_many :orders, dependent: :destroy
  has_many :tickets, dependent: :nullify

  validates :shopify_customer_id, presence: true, uniqueness: { scope: :shopify_store_id }

  def full_name
    [ first_name, last_name ].compact_blank.join(" ").presence
  end

  def shipping_address
    address = shopify_data.is_a?(Hash) ? shopify_data["default_address"] : nil
    address.presence
  end

  def formatted_shipping_address
    address = shipping_address
    return nil unless address.is_a?(Hash)

    [
      address["address1"],
      address["address2"],
      address["city"],
      address["province"],
      address["zip"],
      address["country"]
    ].compact_blank.join(", ").presence
  end
end
