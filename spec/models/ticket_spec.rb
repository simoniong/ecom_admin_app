require "rails_helper"

RSpec.describe Ticket, type: :model do
  let(:email_account) { create(:email_account) }
  let(:ticket) { create(:ticket, email_account: email_account) }

  it "is valid with valid attributes" do
    expect(ticket).to be_valid
  end

  it "generates a UUID id" do
    expect(ticket.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to email_account" do
    expect(ticket.email_account).to eq(email_account)
  end

  it "requires gmail_thread_id" do
    ticket.gmail_thread_id = ""
    expect(ticket).not_to be_valid
  end

  it "enforces gmail_thread_id uniqueness per email_account" do
    duplicate = build(:ticket, email_account: email_account, gmail_thread_id: ticket.gmail_thread_id)
    expect(duplicate).not_to be_valid
  end

  it "allows same gmail_thread_id for different email_accounts" do
    other_account = create(:email_account)
    other_ticket = build(:ticket, email_account: other_account, gmail_thread_id: ticket.gmail_thread_id)
    expect(other_ticket).to be_valid
  end

  it "requires customer_email" do
    ticket.customer_email = ""
    expect(ticket).not_to be_valid
  end

  it "defaults status to new_ticket" do
    t = Ticket.new
    expect(t.status).to eq("new_ticket")
  end

  it "supports all status enum values" do
    expect(Ticket.statuses.keys).to match_array(%w[new_ticket draft draft_confirmed closed])
  end

  it "destroys messages on destroy" do
    create(:message, ticket: ticket)
    expect { ticket.destroy }.to change(Message, :count).by(-1)
  end

  describe "scopes" do
    it ".by_recency orders by last_message_at desc" do
      old = create(:ticket, email_account: email_account, last_message_at: 2.days.ago)
      recent = create(:ticket, email_account: email_account, last_message_at: 1.hour.ago)
      expect(Ticket.by_recency).to eq([ recent, old ])
    end

    it ".for_user returns only tickets for the given user" do
      user = email_account.user
      other_account = create(:email_account)
      other_ticket = create(:ticket, email_account: other_account)

      expect(Ticket.for_user(user)).to include(ticket)
      expect(Ticket.for_user(user)).not_to include(other_ticket)
    end
  end

  describe "#submit_draft!" do
    it "sets draft_reply, draft_reply_at, and transitions to draft" do
      ticket.submit_draft!("Thank you for reaching out.")
      ticket.reload
      expect(ticket).to be_draft
      expect(ticket.draft_reply).to eq("Thank you for reaching out.")
      expect(ticket.draft_reply_at).to be_present
    end

    it "raises when ticket is not in new_ticket status" do
      ticket.update!(status: :draft, draft_reply: "existing")
      expect { ticket.submit_draft!("New draft") }.to raise_error(RuntimeError, /new tickets/)
    end

    it "preserves reopened_reason through submit_draft!" do
      ticket.update!(reopened_reason: "order_shipped")
      ticket.submit_draft!("Shipping update draft")
      expect(ticket.reload.reopened_reason).to eq("order_shipped")
    end
  end

  describe "draft_reply validation" do
    it "requires draft_reply when status is draft" do
      ticket.status = :draft
      ticket.draft_reply = nil
      expect(ticket).not_to be_valid
      expect(ticket.errors[:draft_reply]).to include("can't be blank")
    end

    it "does not require draft_reply when status is new_ticket" do
      ticket.draft_reply = nil
      expect(ticket).to be_valid
    end
  end

  describe "#transition_status!" do
    it "allows draft → draft_confirmed" do
      ticket.update!(status: :draft, draft_reply: "reply")
      ticket.transition_status!("draft_confirmed")
      expect(ticket.reload).to be_draft_confirmed
    end

    it "allows new_ticket → closed (spam) and clears draft" do
      ticket.update!(draft_reply: "some draft", draft_reply_at: Time.current)
      ticket.transition_status!("closed")
      ticket.reload
      expect(ticket).to be_closed
      expect(ticket.draft_reply).to be_nil
      expect(ticket.draft_reply_at).to be_nil
    end

    it "allows draft_confirmed → draft" do
      ticket.update!(status: :draft_confirmed, draft_reply: "reply")
      ticket.transition_status!("draft")
      expect(ticket.reload).to be_draft
    end

    it "allows new_ticket → draft when draft_reply present" do
      ticket.update!(draft_reply: "my reply")
      ticket.transition_status!("draft")
      expect(ticket.reload).to be_draft
      expect(ticket.draft_reply_at).to be_present
    end

    it "raises for new_ticket → draft_confirmed" do
      expect { ticket.transition_status!("draft_confirmed") }.to raise_error(Ticket::InvalidTransition)
    end

    it "raises for closed → draft" do
      ticket.update!(status: :closed)
      expect { ticket.transition_status!("draft") }.to raise_error(Ticket::InvalidTransition)
    end

    it "allows draft → new_ticket (reset draft)" do
      ticket.update!(status: :draft, draft_reply: "reply", draft_reply_at: Time.current)
      ticket.transition_status!("new_ticket")
      ticket.reload
      expect(ticket).to be_new_ticket
      expect(ticket.draft_reply).to be_nil
      expect(ticket.draft_reply_at).to be_nil
    end

    it "allows draft → closed (discard without sending) and clears draft" do
      ticket.update!(status: :draft, draft_reply: "reply", draft_reply_at: Time.current)
      ticket.transition_status!("closed")
      ticket.reload
      expect(ticket).to be_closed
      expect(ticket.draft_reply).to be_nil
      expect(ticket.draft_reply_at).to be_nil
    end

    context "reopened_reason preservation" do
      it "preserves reopened_reason through new_ticket → draft" do
        ticket.update!(reopened_reason: "order_shipped", draft_reply: "draft")
        ticket.transition_status!("draft")
        expect(ticket.reload.reopened_reason).to eq("order_shipped")
      end

      it "preserves reopened_reason through draft → draft_confirmed" do
        ticket.update!(status: :draft, draft_reply: "reply", reopened_reason: "order_delivered")
        ticket.transition_status!("draft_confirmed")
        expect(ticket.reload.reopened_reason).to eq("order_delivered")
      end

      it "preserves reopened_reason through draft_confirmed → draft" do
        ticket.update!(status: :draft_confirmed, draft_reply: "reply", reopened_reason: "order_placed")
        ticket.transition_status!("draft")
        expect(ticket.reload.reopened_reason).to eq("order_placed")
      end

      it "preserves reopened_reason through draft → new_ticket" do
        ticket.update!(status: :draft, draft_reply: "reply", reopened_reason: "customer_reply")
        ticket.transition_status!("new_ticket")
        expect(ticket.reload.reopened_reason).to eq("customer_reply")
      end

      it "clears reopened_reason when transitioning to closed" do
        ticket.update!(reopened_reason: "order_shipped")
        ticket.transition_status!("closed")
        expect(ticket.reload.reopened_reason).to be_nil
      end
    end
  end

  describe ".reorder_positions!" do
    it "updates positions based on id order" do
      t1 = create(:ticket, email_account: email_account, position: 0)
      t2 = create(:ticket, email_account: email_account, position: 1)
      t3 = create(:ticket, email_account: email_account, position: 2)

      Ticket.reorder_positions!([ t3.id, t1.id, t2.id ])

      expect(t3.reload.position).to eq(0)
      expect(t1.reload.position).to eq(1)
      expect(t2.reload.position).to eq(2)
    end
  end

  describe ".by_position" do
    it "orders by position then last_message_at" do
      t1 = create(:ticket, email_account: email_account, position: 2)
      t2 = create(:ticket, email_account: email_account, position: 0)
      t3 = create(:ticket, email_account: email_account, position: 1)

      expect(Ticket.by_position).to eq([ t2, t3, t1 ])
    end
  end
end
