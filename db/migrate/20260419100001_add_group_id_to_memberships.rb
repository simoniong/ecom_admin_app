class AddGroupIdToMemberships < ActiveRecord::Migration[8.1]
  def change
    add_reference :memberships, :group, type: :uuid, foreign_key: true, null: true, index: true
  end
end
