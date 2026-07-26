class AddVideo3SecWatchedToAdUnitDailyMetrics < ActiveRecord::Migration[8.1]
  def change
    add_column :ad_unit_daily_metrics, :video_3_sec_watched, :integer, default: 0

    # Meta does not emit video_continuous_2_sec_watched_actions for this
    # account's ads at all (confirmed against production responses for a
    # video-rich ad) -- the column has been permanently zero since launch.
    # The real metric ("3-Second Video Views") lives in the `actions` array
    # under action_type "video_view" and is now captured as
    # video_3_sec_watched above. Dropping rather than leaving this behind so
    # it doesn't read like real data to the next person.
    remove_column :ad_unit_daily_metrics, :video_continuous_2_sec_watched, :integer, default: 0
  end
end
