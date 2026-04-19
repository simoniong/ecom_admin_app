require "rails_helper"

RSpec.describe GroupAssignable do
  shared_examples "a group-assignable resource" do |factory_name|
    let(:company) { create(:company) }

    it "allows no group when company has no groups" do
      record = build(factory_name, company: company)
      expect(record).to be_valid
    end

    it "rejects no group when company has at least one group" do
      create(:group, company: company)
      record = build(factory_name, company: company, group: nil)
      expect(record).not_to be_valid
      expect(record.errors[:group_id]).to be_present
    end

    it "accepts a group belonging to the same company" do
      group = create(:group, company: company)
      record = build(factory_name, company: company, group: group)
      expect(record).to be_valid
    end

    it "rejects a group from a different company" do
      other_group = create(:group, company: create(:company))
      record = build(factory_name, company: company, group: other_group)
      expect(record).not_to be_valid
      expect(record.errors[:group_id]).to be_present
    end
  end

  describe ShopifyStore do
    include_examples "a group-assignable resource", :shopify_store
  end

  describe AdAccount do
    include_examples "a group-assignable resource", :ad_account
  end

  describe EmailAccount do
    include_examples "a group-assignable resource", :email_account
  end
end
