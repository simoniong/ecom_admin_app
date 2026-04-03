class Customer < ApplicationRecord
  belongs_to :shopify_store, optional: true
  has_many :orders, dependent: :destroy
  has_many :tickets

  validates :shopify_customer_id, presence: true, uniqueness: { scope: :shopify_store_id }

  def full_name
    [ first_name, last_name ].compact_blank.join(" ").presence
  end
end
