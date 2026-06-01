class AddZoneToShippingRateCardRates < ActiveRecord::Migration[8.1]
  def change
    add_column :shipping_rate_card_rates, :zone, :string
    add_index  :shipping_rate_card_rates, [ :version_id, :zone ]
  end
end
