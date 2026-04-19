require "rails_helper"

RSpec.describe "Resource group reassignment", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let!(:group_a) { create(:group, company: company, name: "Sales") }
  let!(:group_b) { create(:group, company: company, name: "Support") }

  describe "ShopifyStore" do
    it "owner can reassign a store's group" do
      store = create(:shopify_store, company: company, user: owner, group: group_a)
      sign_in owner

      patch shopify_store_path(id: store.id), params: { shopify_store: { group_id: group_b.id } }

      expect(response).to redirect_to(shopify_store_path(id: store.id))
      expect(store.reload.group).to eq(group_b)
    end

    it "blocks a member from reassigning a store's group" do
      store = create(:shopify_store, company: company, user: owner, group: group_a)
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[shopify_stores], group: group_a)
      sign_in member
      patch switch_company_path(id: company.id)

      patch shopify_store_path(id: store.id), params: { shopify_store: { group_id: group_b.id } }

      expect(response).to redirect_to(shopify_store_path(id: store.id))
      expect(store.reload.group).to eq(group_a)
    end
  end

  describe "AdAccount" do
    it "owner can reassign an ad account's group" do
      ad = create(:ad_account, company: company, user: owner, group: group_a)
      sign_in owner

      patch ad_account_path(id: ad.id), params: { ad_account: { group_id: group_b.id } }

      expect(response).to redirect_to(ad_account_path(id: ad.id))
      expect(ad.reload.group).to eq(group_b)
    end
  end

  describe "EmailAccount" do
    it "owner can reassign an email account's group" do
      ea = create(:email_account, company: company, user: owner, group: group_a)
      sign_in owner

      patch email_account_path(id: ea.id), params: { email_account: { group_id: group_b.id } }

      expect(response).to redirect_to(email_account_path(id: ea.id))
      expect(ea.reload.group).to eq(group_b)
    end

    it "preserves send_window update path when group_id not supplied" do
      ea = create(:email_account, company: company, user: owner, group: group_a)
      sign_in owner

      patch email_account_path(id: ea.id), params: {
        email_account: { send_window_from_hour: 9, send_window_from_minute: 0, send_window_to_hour: 21, send_window_to_minute: 0 }
      }

      expect(response).to redirect_to(email_account_path(id: ea.id))
      expect(ea.reload.send_window_from_hour).to eq(9)
      expect(ea.send_window_to_hour).to eq(21)
    end
  end
end
