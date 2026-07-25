class AddCreativeSyncFieldsToAdAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :ad_accounts, :creative_synced_from_date, :date
    add_column :ad_accounts, :creative_synced_through_date, :date
    add_column :ad_accounts, :creative_backfill_attempts, :integer, default: 0, null: false
    add_column :ad_accounts, :creative_backfill_next_attempt_at, :datetime
  end
end
