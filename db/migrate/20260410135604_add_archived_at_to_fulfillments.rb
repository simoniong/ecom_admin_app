class AddArchivedAtToFulfillments < ActiveRecord::Migration[8.1]
  def change
    add_column :fulfillments, :archived_at, :datetime
  end
end
