require "rails_helper"

RSpec.describe EmailWorkflowStepJob, type: :job do
  let(:shopify_store) { create(:shopify_store, timezone: "America/New_York") }
  let(:email_account) { create(:email_account, shopify_store: shopify_store, user: shopify_store.user, company: shopify_store.company) }
  let(:customer) { create(:customer, shopify_store: shopify_store) }
  let(:order) { create(:order, customer: customer, shopify_store: shopify_store) }
  let(:ticket) { create(:ticket, email_account: email_account, customer: customer) }
  let(:workflow) { create(:email_workflow, shopify_store: shopify_store) }
  let(:run) do
    create(:email_workflow_run,
      email_workflow: workflow, order: order, ticket: ticket,
      status: "running", started_at: 1.hour.ago, current_step_position: 0)
  end

  describe "#perform" do
    context "when run is not running" do
      it "does nothing for completed runs" do
        run.update!(status: "completed", completed_at: Time.current)
        expect { described_class.perform_now(run.id) }.not_to change { run.reload.status }
      end

      it "does nothing for missing runs" do
        expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
      end
    end

    context "when customer has replied" do
      before do
        create(:message, ticket: ticket, from: "customer@example.com", sent_at: Time.current)
      end

      it "cancels the run" do
        described_class.perform_now(run.id)
        expect(run.reload.status).to eq("cancelled")
        expect(run.cancelled_reason).to eq("customer_replied")
      end
    end

    context "when workflow is disabled" do
      before { workflow.update!(enabled: false) }

      it "cancels the run" do
        described_class.perform_now(run.id)
        expect(run.reload.status).to eq("cancelled")
        expect(run.cancelled_reason).to eq("workflow_disabled")
      end
    end

    context "when no more steps" do
      it "completes the run" do
        # No steps exist at position 0
        described_class.perform_now(run.id)
        expect(run.reload.status).to eq("completed")
      end
    end

    context "with a delay step" do
      let!(:delay_step) do
        create(:email_workflow_step, :delay, email_workflow: workflow, position: 0,
          config: { "amount" => 2, "unit" => "hours" })
      end

      it "schedules the next job execution with delay" do
        expect {
          described_class.perform_now(run.id)
        }.to have_enqueued_job(described_class).with(run.id)
        expect(run.reload.current_step_position).to eq(1)
      end
    end

    context "with a send_email step" do
      let!(:send_step) do
        create(:email_workflow_step, :send_email, email_workflow: workflow, position: 0,
          config: { "instruction" => "Draft a shipping update email" })
      end

      before do
        allow(DiscordWebhookService).to receive(:notify_workflow_action)
      end

      it "sets ticket to new_ticket and sends Discord notification" do
        ticket.update!(status: :closed)
        described_class.perform_now(run.id)
        expect(ticket.reload.status).to eq("new_ticket")
        expect(DiscordWebhookService).to have_received(:notify_workflow_action)
          .with(ticket, "Draft a shipping update email")
      end

      it "sets reopened_reason to the workflow trigger_event" do
        ticket.update!(status: :closed, reopened_reason: nil)
        workflow.update!(trigger_event: "order_shipped")
        described_class.perform_now(run.id)
        expect(ticket.reload.reopened_reason).to eq("order_shipped")
      end

      it "completes the run when it is the last step" do
        described_class.perform_now(run.id)
        expect(run.reload.status).to eq("completed")
      end

      context "with a following step" do
        let!(:next_step) do
          create(:email_workflow_step, :delay, email_workflow: workflow, position: 1)
        end

        it "advances to next step and enqueues job" do
          expect {
            described_class.perform_now(run.id)
          }.to have_enqueued_job(described_class).with(run.id)
          expect(run.reload.current_step_position).to eq(1)
        end
      end
    end

    context "with delay calculation" do
      let!(:delay_step) do
        create(:email_workflow_step, :delay, email_workflow: workflow, position: 0,
          config: { "amount" => 1, "unit" => "days", "until_time" => "09:00" })
      end

      it "calculates delay with until_time" do
        described_class.perform_now(run.id)
        expect(run.reload.current_step_position).to eq(1)
      end

      it "calculates delay with only_days filter" do
        delay_step.update!(config: { "amount" => 1, "unit" => "days", "only_days" => [ 1, 2, 3, 4, 5 ] })
        described_class.perform_now(run.id)
        expect(run.reload.current_step_position).to eq(1)
      end
    end
  end
end
