require "rails_helper"

RSpec.describe "config/recurring.yml" do
  let(:schedule) { YAML.load_file(Rails.root.join("config/recurring.yml")) }

  describe "purge_sync_runs" do
    it "purges sync runs older than 7 days, once a day at 5am" do
      entry = schedule.dig("production", "purge_sync_runs")

      expect(entry).to eq(
        "command" => "SyncRun.purge_older_than(7.days)",
        "schedule" => "every day at 5am"
      )
    end
  end
end
