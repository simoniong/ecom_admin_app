class AddPaidAtToOrders < ActiveRecord::Migration[8.1]
  def up
    add_column :orders, :paid_at, :datetime
    add_index :orders, [ :shopify_store_id, :paid_at ], name: "idx_orders_store_paid_at"

    # Backfill in Ruby, one row at a time, rather than a single
    # `UPDATE ... (shopify_data->>'processed_at')::timestamptz`. shopify_data is
    # raw third-party JSON this app never validates on write, and a Postgres cast
    # raises on the first unparseable value — taking the whole migration with it.
    # A regex guard does not save it either: '2026-99-99' is well-formed and
    # still fails to cast. One bad row must cost one row, not the deploy.
    Order.reset_column_information
    Order.where.not(shopify_data: nil).find_each(batch_size: 500) do |order|
      raw = order.shopify_data.is_a?(Hash) ? order.shopify_data["processed_at"] : nil
      next if raw.blank?

      begin
        order.update_column(:paid_at, Time.zone.parse(raw.to_s))
      rescue ArgumentError, TypeError => e
        say "skipped Order #{order.id}: unparseable processed_at #{raw.inspect} (#{e.class})"
      end
    end
  end

  def down
    remove_index :orders, name: "idx_orders_store_paid_at"
    remove_column :orders, :paid_at
  end
end
