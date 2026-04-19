require "rails_helper"

RSpec.describe Companies::CreateWithOwner do
  let!(:user) { create(:user) }

  it "creates a Company and an owner Membership for the user in a transaction" do
    expect {
      described_class.new(user, name: "Acme", locale: "en").call
    }.to change(Company, :count).by(1).and change(Membership, :count).by(1)

    company = Company.find_by(name: "Acme")
    expect(company.locale).to eq("en")

    membership = user.membership_for(company)
    expect(membership).to be_present
    expect(membership).to be_owner
    expect(membership.group).to be_nil
  end

  it "rolls back both records when company is invalid" do
    expect {
      expect {
        described_class.new(user, name: "", locale: "en").call
      }.to raise_error(ActiveRecord::RecordInvalid)
    }.not_to change(Company, :count)
  end
end
