require "rails_helper"

RSpec.describe SyncAcknowledgement, type: :model do
  it "is valid with valid attributes" do
    expect(create(:sync_acknowledgement)).to be_valid
  end

  it "enforces uniqueness scoped to user, company, and source" do
    ack = create(:sync_acknowledgement)
    duplicate = build(:sync_acknowledgement, user: ack.user, company: ack.company, source: ack.source)

    expect(duplicate).not_to be_valid
  end

  it "allows the same source for a different user in the same company" do
    ack = create(:sync_acknowledgement)
    other_user = create(:user)
    other = build(:sync_acknowledgement, user: other_user, company: ack.company, source: ack.source)

    expect(other).to be_valid
  end

  it "validates source inclusion in SyncRun::SOURCES" do
    ack = build(:sync_acknowledgement, source: "invalid_source")

    expect(ack).not_to be_valid
  end
end
