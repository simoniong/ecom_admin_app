require "rails_helper"

RSpec.describe Groups::CreateFirstGroup do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }

  it "creates a group and assigns every unassigned membership, store, ad account, and email account" do
    member_user = create(:user)
    create(:membership, company: company, user: member_user, role: :member, permissions: %w[orders])
    store = create(:shopify_store, company: company, user: owner)
    ad_account = create(:ad_account, company: company, user: owner)
    email_account = create(:email_account, company: company, user: owner)

    result = described_class.new(company, name: "Default").call

    expect(result.group.reload.name).to eq("Default")
    expect(result.backfilled_membership_count).to eq(1)
    expect(result.backfilled_shopify_stores_count).to eq(1)
    expect(result.backfilled_ad_accounts_count).to eq(1)
    expect(result.backfilled_email_accounts_count).to eq(1)

    expect(member_user.membership_for(company).reload.group).to eq(result.group)
    expect(store.reload.group).to eq(result.group)
    expect(ad_account.reload.group).to eq(result.group)
    expect(email_account.reload.group).to eq(result.group)
  end

  it "does not touch the owner's membership (owners must have no group)" do
    result = described_class.new(company, name: "Default").call

    expect(owner.membership_for(company).reload.group).to be_nil
    expect(result.backfilled_membership_count).to eq(0)
  end

  it "raises RecordInvalid on a blank name without creating any records" do
    expect {
      described_class.new(company, name: "").call
    }.to raise_error(ActiveRecord::RecordInvalid)

    expect(company.groups.count).to eq(0)
  end

  it "leaves resources already assigned to a group untouched" do
    existing_group = create(:group, company: company)
    assigned_store = create(:shopify_store, company: company, user: owner, group: existing_group)

    # Simulate a legacy rogue record with group_id nil despite company having groups
    # (bypasses validations via update_columns).
    rogue_store = create(:shopify_store, company: company, user: owner, group: existing_group)
    rogue_store.update_columns(group_id: nil)

    result = described_class.new(company, name: "Second Department").call

    expect(assigned_store.reload.group).to eq(existing_group)
    expect(rogue_store.reload.group).to eq(result.group)
  end
end
