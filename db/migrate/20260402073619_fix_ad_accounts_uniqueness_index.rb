class FixAdAccountsUniquenessIndex < ActiveRecord::Migration[8.1]
  def up
    remove_index :ad_accounts, name: "index_ad_accounts_on_platform_and_account_id", if_exists: true
    add_index :ad_accounts, [ :user_id, :platform, :account_id ],
              unique: true, name: "index_ad_accounts_on_user_id_and_platform_and_account_id", if_not_exists: true
  end

  def down
    # The target index (user_id, platform, account_id) may have been created by
    # create_ad_accounts migration — do not remove it on rollback.
  end
end
