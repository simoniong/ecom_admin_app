class Customer < ApplicationRecord
  has_many :orders, dependent: :destroy
  has_many :tickets

  validates :shopify_customer_id, presence: true, uniqueness: true

  def full_name
    [ first_name, last_name ].compact_blank.join(" ").presence
  end
end
