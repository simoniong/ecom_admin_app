require "rails_helper"

RSpec.describe EmailScheduler do
  let(:customer) { create(:customer, timezone: "America/New_York") }
  let(:ticket) { create(:ticket, :draft, customer: customer) }

  describe ".schedule!" do
    it "sets scheduled_send_at and scheduled_job_id" do
      ticket.update!(status: :draft_confirmed)

      freeze_time do
        described_class.schedule!(ticket)
        ticket.reload

        expect(ticket.scheduled_send_at).to be_present
        expect(ticket.scheduled_job_id).to be_present
        expect(ticket.scheduled_send_at).to be >= 10.minutes.from_now
      end
    end

    it "schedules within 8am-10pm customer timezone" do
      ticket.update!(status: :draft_confirmed)

      # Simulate 3am in New York (8am UTC in winter)
      travel_to Time.zone.parse("2026-03-26 07:00:00 UTC") do
        described_class.schedule!(ticket)
        ticket.reload

        send_time_ny = ticket.scheduled_send_at.in_time_zone("America/New_York")
        expect(send_time_ny.hour).to be >= 8
        expect(send_time_ny.hour).to be < 22
      end
    end

    it "schedules for next morning if after 10pm customer time" do
      ticket.update!(status: :draft_confirmed)

      # 11pm in New York = 3am UTC next day (EST = UTC-5, but in March EDT = UTC-4)
      travel_to Time.zone.parse("2026-03-27 03:00:00 UTC") do
        described_class.schedule!(ticket)
        ticket.reload

        send_time_ny = ticket.scheduled_send_at.in_time_zone("America/New_York")
        expect(send_time_ny.hour).to eq(8)
        expect(send_time_ny.day).to eq(27) # next day
      end
    end

    it "uses UTC when no customer" do
      ticket_no_customer = create(:ticket, :draft, customer: nil)
      ticket_no_customer.update!(status: :draft_confirmed)

      described_class.schedule!(ticket_no_customer)
      expect(ticket_no_customer.reload.scheduled_send_at).to be_present
    end
  end

  describe ".cancel!" do
    it "clears scheduled_send_at and scheduled_job_id" do
      ticket.update!(status: :draft_confirmed, scheduled_send_at: 1.hour.from_now, scheduled_job_id: "job-123")

      described_class.cancel!(ticket)
      ticket.reload

      expect(ticket.scheduled_send_at).to be_nil
      expect(ticket.scheduled_job_id).to be_nil
    end
  end
end
