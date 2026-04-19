require "rails_helper"

RSpec.describe TrackingService do
  let(:service) { described_class.new(api_key: "test-api-key") }

  describe "#initialize" do
    it "raises MissingApiKeyError when api_key is blank" do
      expect { described_class.new(api_key: nil) }.to raise_error(TrackingService::MissingApiKeyError)
      expect { described_class.new(api_key: "") }.to raise_error(TrackingService::MissingApiKeyError)
    end

    it "sends the given api_key in request headers" do
      stub = stub_request(:post, TrackingService::REGISTER_URL)
        .with(headers: { "17token" => "per-company-key" })
        .to_return(
          status: 200,
          body: { data: { accepted: [] } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      described_class.new(api_key: "per-company-key").register([ "TEST" ])

      expect(stub).to have_been_requested
    end
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
                    shipping_info: {
                      shipper_address: { country: "CN" },
                      recipient_address: { country: "US" }
                    },
                    time_metrics: { days_of_transit: 5 },
                    tracking: {
                      providers: [
                        {
                          provider: { name: "China Post", country: "CN" },
                          events: [
                            { description: "In transit", time_iso: "2026-03-24T08:00:00+08:00", location: "Los Angeles" }
                          ]
                        },
                        {
                          provider: { name: "USPS", country: "US" },
                          events: [
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
      result = results.first
      expect(results.length).to eq(1)
      expect(result[:tracking_number]).to eq("TRACK123")
      expect(result[:status]).to eq("Delivered")
      expect(result[:sub_status]).to eq("Delivered_Other")
      expect(result[:last_event]).to eq("Delivered to recipient")
      expect(result[:last_event_time]).to eq("2026-03-25T10:00:00+08:00")
      expect(result[:origin_country]).to eq("CN")
      expect(result[:destination_country]).to eq("US")
      expect(result[:origin_carrier]).to eq("China Post")
      expect(result[:destination_carrier]).to eq("USPS")
      expect(result[:transit_days]).to eq(5)
      expect(result[:events].length).to eq(2)
      expect(result[:events].first[:description]).to eq("In transit")
      expect(result[:events].first[:location]).to eq("Los Angeles")
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
      result = results.first
      expect(result[:tracking_number]).to eq("TRACK456")
      expect(result[:status]).to be_nil
      expect(result[:sub_status]).to be_nil
      expect(result[:last_event]).to be_nil
      expect(result[:last_event_time]).to be_nil
      expect(result[:origin_country]).to be_nil
      expect(result[:destination_country]).to be_nil
      expect(result[:origin_carrier]).to be_nil
      expect(result[:destination_carrier]).to be_nil
      expect(result[:transit_days]).to be_nil
      expect(result[:events]).to eq([])
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

    it "merges events from multiple providers and extracts carriers" do
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
                        { provider: { name: "YTO Express" }, events: [ { description: "Picked up", time_iso: "2026-03-20T08:00:00+08:00", location: "Shanghai" } ] },
                        { provider: { name: "DHL" }, events: [ { description: "Delivered", time_iso: "2026-03-25T10:00:00+08:00", location: "New York" } ] }
                      ]
                    }
                  }
                }
              ]
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.track([ "TRACK_MULTI" ]).first
      expect(result[:events].length).to eq(2)
      expect(result[:events].map { |e| e[:location] }).to eq([ "Shanghai", "New York" ])
      expect(result[:origin_carrier]).to eq("YTO Express")
      expect(result[:destination_carrier]).to eq("DHL")
    end

    it "sets destination_carrier to nil when only one provider" do
      stub_request(:post, TrackingService::TRACK_URL)
        .to_return(
          status: 200,
          body: {
            data: {
              accepted: [
                {
                  number: "TRACK_SINGLE",
                  track_info: {
                    latest_status: { status: "InTransit" },
                    latest_event: { description: "In transit", time_iso: "2026-03-24T08:00:00+08:00" },
                    tracking: {
                      providers: [
                        { provider: { name: "China Post" }, events: [ { description: "In transit", time_iso: "2026-03-24T08:00:00+08:00", location: "Beijing" } ] }
                      ]
                    }
                  }
                }
              ]
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = service.track([ "TRACK_SINGLE" ]).first
      expect(result[:origin_carrier]).to eq("China Post")
      expect(result[:destination_carrier]).to be_nil
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
end
