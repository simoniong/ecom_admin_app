require "rails_helper"

RSpec.describe TrackingService do
  let(:service) { described_class.new }

  before do
    allow(Rails.application.credentials).to receive(:dig).with(:seventeen_track, :api_key).and_return("test-api-key")
  end

  describe "#track" do
    it "returns tracking info for given numbers" do
      stub_request(:post, TrackingService::API_URL)
        .to_return(
          status: 200,
          body: {
            data: {
              accepted: [
                {
                  number: "TRACK123",
                  track: {
                    e: "Delivered",
                    z0: { z: "Delivered to recipient", a: "2026-03-25 10:00:00" },
                    z1: [
                      { z: "In transit", a: "2026-03-24 08:00:00", c: "Los Angeles" },
                      { z: "Delivered", a: "2026-03-25 10:00:00", c: "New York" }
                    ]
                  }
                }
              ]
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      results = service.track([ "TRACK123" ])
      expect(results.length).to eq(1)
      expect(results.first[:tracking_number]).to eq("TRACK123")
      expect(results.first[:status]).to eq("Delivered")
      expect(results.first[:events].length).to eq(2)
    end

    it "returns empty array for empty input" do
      expect(service.track([])).to eq([])
    end

    it "raises on API error" do
      stub_request(:post, TrackingService::API_URL)
        .to_return(status: 500, body: "Server Error")

      expect { service.track([ "TRACK1" ]) }.to raise_error(RuntimeError, /17Track API error/)
    end
  end
end
