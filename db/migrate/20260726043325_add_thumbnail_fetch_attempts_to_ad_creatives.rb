class AddThumbnailFetchAttemptsToAdCreatives < ActiveRecord::Migration[8.1]
  def change
    add_column :ad_creatives, :thumbnail_fetch_attempts, :integer, null: false, default: 0
  end
end
