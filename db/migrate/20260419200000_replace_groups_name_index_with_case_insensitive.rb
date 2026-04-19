class ReplaceGroupsNameIndexWithCaseInsensitive < ActiveRecord::Migration[8.1]
  def change
    remove_index :groups, [ :company_id, :name ]
    add_index :groups, "company_id, LOWER(name)", unique: true,
              name: :index_groups_on_company_id_and_lower_name
  end
end
