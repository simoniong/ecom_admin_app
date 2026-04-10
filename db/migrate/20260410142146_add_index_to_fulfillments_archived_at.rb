class AddIndexToFulfillmentsArchivedAt < ActiveRecord::Migration[8.1]
  def change
    add_index :fulfillments, :archived_at
  end
end
