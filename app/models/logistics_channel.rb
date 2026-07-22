class LogisticsChannel < ApplicationRecord
  belongs_to :logistics_account
  has_one :company, through: :logistics_account

  validates :name, presence: true
  validates :product_id, presence: true
  validates :shopify_carrier_name, presence: true
  validates :tracking_url_template, presence: true
  validates :label_print_type, presence: true
end
