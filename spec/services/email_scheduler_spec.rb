require "rails_helper"

RSpec.describe EmailScheduler do
  let(:customer) { create(:customer, timezone: "America/New_York") }
  let(:email_account) { create(:email_account) }
  let(:ticket) { create(:ticket, :draft, customer: customer, email_account: email_account) }

  describe ".schedule!" do
    it "sets scheduled_send_at and scheduled_job_id from ActiveJob" do
      ticket.update!(status: :draft_confirmed)

      freeze_time do
        described_class.schedule!(ticket)
        ticket.reload

        expect(ticket.scheduled_send_at).to be_present
        expect(ticket.scheduled_job_id).to be_present
        expect(ticket.scheduled_send_at).to be >= 5.minutes.from_now

        # scheduled_job_id should be a valid UUID (ActiveJob's job_id)
        expect(ticket.scheduled_job_id).to match(/\A[0-9a-f-]{36}\z/)
      end
    end

    it "schedules within default 8am-10pm customer timezone" do
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

    it "uses America/New_York when no customer" do
      ticket_no_customer = create(:ticket, :draft, customer: nil, email_account: email_account)
      ticket_no_customer.update!(status: :draft_confirmed)

      # 3am ET = 7am/8am UTC depending on DST
      travel_to Time.zone.parse("2026-03-26 07:00:00 UTC") do
        described_class.schedule!(ticket_no_customer)
        ticket_no_customer.reload

        expect(ticket_no_customer.scheduled_send_at).to be_present
        send_time_et = ticket_no_customer.scheduled_send_at.in_time_zone("America/New_York")
        expect(send_time_et.hour).to be >= 8
        expect(send_time_et.hour).to be < 22
      end
    end

    context "with custom send window" do
      before do
        email_account.update!(
          send_window_from_hour: 10,
          send_window_from_minute: 30,
          send_window_to_hour: 18,
          send_window_to_minute: 0
        )
      end

      it "respects custom window start time" do
        ticket.update!(status: :draft_confirmed)

        # 9am in New York — before 10:30am custom window
        travel_to Time.zone.parse("2026-03-26 13:00:00 UTC") do
          described_class.schedule!(ticket)
          ticket.reload

          send_time_ny = ticket.scheduled_send_at.in_time_zone("America/New_York")
          expect(send_time_ny.hour).to eq(10)
          expect(send_time_ny.min).to eq(30)
        end
      end

      it "respects custom window end time" do
        ticket.update!(status: :draft_confirmed)

        # 7pm in New York — after 6pm custom window end
        travel_to Time.zone.parse("2026-03-26 23:00:00 UTC") do
          described_class.schedule!(ticket)
          ticket.reload

          send_time_ny = ticket.scheduled_send_at.in_time_zone("America/New_York")
          # Should schedule for next day at 10:30am
          expect(send_time_ny.hour).to eq(10)
          expect(send_time_ny.min).to eq(30)
          expect(send_time_ny.day).to eq(27)
        end
      end

      it "sends immediately when within custom window" do
        ticket.update!(status: :draft_confirmed)

        # 2pm in New York — within 10:30am-6pm custom window
        travel_to Time.zone.parse("2026-03-26 18:00:00 UTC") do
          described_class.schedule!(ticket)
          ticket.reload

          expect(ticket.scheduled_send_at).to be <= 6.minutes.from_now
        end
      end
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
