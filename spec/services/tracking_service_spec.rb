require "rails_helper"

RSpec.describe TrackingService do
  let(:service) { described_class.new }

  before do
    allow(Rails.application.credentials).to receive(:dig).with(:seventeen_track, :api_key).and_return("test-api-key")
  end

  describe "#register" do
    it "registers tracking numbers with 17Track" do
      stub_request(:post, TrackingService::REGISTER_URL)
        .to_return(
          status: 200,
          body: {
            data: {
              accepted: [ { number: "TRACK123" } ],
              rejected: []
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.register([ "TRACK123" ])
      expect(result.length).to eq(1)
      expect(result.first["number"]).to eq("TRACK123")
    end

    it "returns empty array for empty input" do
      expect(service.register([])).to eq([])
    end

    it "raises on API error" do
      stub_request(:post, TrackingService::REGISTER_URL)
        .to_return(status: 500, body: "Server Error")

      expect { service.register([ "TRACK1" ]) }.to raise_error(RuntimeError, /17Track register error/)
    end
  end

  describe "#track" do
    it "returns tracking info for given numbers" do
      stub_request(:post, TrackingService::TRACK_URL)
        .to_return(
          status: 200,
          body: {
            data: {
              accepted: [
                {
                  number: "TRACK123",
                  track_info: {
                    latest_status: { status: "Delivered", sub_status: "Delivered_Other" },
                    latest_event: {
                      description: "Delivered to recipient",
                      time_iso: "2026-03-25T10:00:00+08:00",
                      location: "New York, US"
                    },
                    tracking: {
                      providers: [
                        {
                          events: [
                            { description: "In transit", time_iso: "2026-03-24T08:00:00+08:00", location: "Los Angeles" },
                            { description: "Delivered to recipient", time_iso: "2026-03-25T10:00:00+08:00", location: "New York" }
                          ]
                        }
                      ]
                    }
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
      expect(results.first[:last_event]).to eq("Delivered to recipient")
      expect(results.first[:last_event_time]).to eq("2026-03-25T10:00:00+08:00")
      expect(results.first[:events].length).to eq(2)
      expect(results.first[:events].first[:description]).to eq("In transit")
      expect(results.first[:events].first[:location]).to eq("Los Angeles")
    end

    it "handles missing track_info gracefully" do
      stub_request(:post, TrackingService::TRACK_URL)
        .to_return(
          status: 200,
          body: {
            data: {
              accepted: [ { number: "TRACK456" } ]
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      results = service.track([ "TRACK456" ])
      expect(results.first[:tracking_number]).to eq("TRACK456")
      expect(results.first[:status]).to be_nil
      expect(results.first[:last_event]).to be_nil
      expect(results.first[:last_event_time]).to be_nil
      expect(results.first[:events]).to eq([])
    end

    it "handles missing providers gracefully" do
      stub_request(:post, TrackingService::TRACK_URL)
        .to_return(
          status: 200,
          body: {
            data: {
              accepted: [
                {
                  number: "TRACK789",
                  track_info: {
                    latest_status: { status: "NotFound" },
                    latest_event: {},
                    tracking: { providers: [] }
                  }
                }
              ]
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      results = service.track([ "TRACK789" ])
      expect(results.first[:status]).to eq("NotFound")
      expect(results.first[:events]).to eq([])
    end

    it "merges events from multiple providers" do
      stub_request(:post, TrackingService::TRACK_URL)
        .to_return(
          status: 200,
          body: {
            data: {
              accepted: [
                {
                  number: "TRACK_MULTI",
                  track_info: {
                    latest_status: { status: "Delivered" },
                    latest_event: { description: "Delivered", time_iso: "2026-03-25T10:00:00+08:00" },
                    tracking: {
                      providers: [
                        { events: [ { description: "Picked up", time_iso: "2026-03-20T08:00:00+08:00", location: "Shanghai" } ] },
                        { events: [ { description: "Delivered", time_iso: "2026-03-25T10:00:00+08:00", location: "New York" } ] }
                      ]
                    }
                  }
                }
              ]
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      results = service.track([ "TRACK_MULTI" ])
      expect(results.first[:events].length).to eq(2)
      expect(results.first[:events].map { |e| e[:location] }).to eq([ "Shanghai", "New York" ])
    end

    it "tracks multiple numbers in one request" do
      stub_request(:post, TrackingService::TRACK_URL)
        .to_return(
          status: 200,
          body: {
            data: {
              accepted: [
                { number: "T1", track_info: { latest_status: { status: "InTransit" }, latest_event: {}, tracking: { providers: [] } } },
                { number: "T2", track_info: { latest_status: { status: "Delivered" }, latest_event: {}, tracking: { providers: [] } } }
              ]
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      results = service.track([ "T1", "T2" ])
      expect(results.length).to eq(2)
      expect(results.map { |r| r[:status] }).to eq([ "InTransit", "Delivered" ])
    end

    it "handles nil accepted in response" do
      stub_request(:post, TrackingService::TRACK_URL)
        .to_return(
          status: 200,
          body: { data: { accepted: nil } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect(service.track([ "TRACK1" ])).to eq([])
    end

    it "returns empty array for empty input" do
      expect(service.track([])).to eq([])
    end

    it "raises on API error" do
      stub_request(:post, TrackingService::TRACK_URL)
        .to_return(status: 500, body: "Server Error")

      expect { service.track([ "TRACK1" ]) }.to raise_error(RuntimeError, /17Track API error/)
    end
  end

  describe "#initialize" do
    it "reads API key from ENV variable" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SEVENTEEN_TRACK_API_KEY").and_return("env-api-key")

      svc = described_class.new
      stub_request(:post, TrackingService::REGISTER_URL)
        .with(headers: { "17token" => "env-api-key" })
        .to_return(
          status: 200,
          body: { data: { accepted: [] } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      svc.register([ "TEST" ])
    end
  end
end
