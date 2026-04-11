require "rails_helper"

RSpec.describe "Invitations", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }

  describe "GET /invitations" do
    it "returns success for owner" do
      sign_in owner
      get invitations_path
      expect(response).to have_http_status(:success)
    end

    it "redirects member" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard])
      sign_in member
      patch switch_company_path(id: company.id)
      get invitations_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "POST /invitations" do
    it "creates an invitation" do
      sign_in owner
      expect {
        post invitations_path, params: {
          invitation: { email: "new@example.com", role: "member", permissions: %w[orders tickets] }
        }
      }.to change(Invitation, :count).by(1)
      expect(response).to redirect_to(invitations_path)

      invitation = Invitation.last
      expect(invitation.email).to eq("new@example.com")
      expect(invitation.role).to eq("member")
      expect(invitation.permissions).to eq(%w[orders tickets])
    end

    it "enqueues invitation email" do
      sign_in owner
      expect {
        post invitations_path, params: {
          invitation: { email: "new@example.com", role: "member", permissions: %w[orders] }
        }
      }.to have_enqueued_mail(InvitationMailer, :invite)
    end

    it "rejects invalid email" do
      sign_in owner
      post invitations_path, params: {
        invitation: { email: "", role: "member", permissions: [] }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /invitations/:id" do
    it "cancels a pending invitation" do
      sign_in owner
      invitation = create(:invitation, company: company, invited_by: owner)
      expect {
        delete invitation_path(id: invitation.id)
      }.to change(Invitation, :count).by(-1)
      expect(response).to redirect_to(invitations_path)
    end
  end

  describe "permission enforcement" do
    it "blocks member from pages not in their permissions" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard orders])

      sign_in member
      patch switch_company_path(id: company.id)

      get tickets_path
      expect(response).to redirect_to(authenticated_root_path)
    end

    it "allows member to access permitted pages" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard orders])
      sign_in member
      patch switch_company_path(id: company.id)

      get orders_path
      expect(response).to have_http_status(:success)
    end

    it "allows owner to access all pages" do
      sign_in owner
      get orders_path
      expect(response).to have_http_status(:success)
      get tickets_path
      expect(response).to have_http_status(:success)
    end

    it "maps campaign_display_templates permission to ad_campaigns" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard ad_campaigns])
      ad_account = create(:ad_account, user: owner, company: company)
      campaign = create(:ad_campaign, ad_account: ad_account)
      sign_in member
      patch switch_company_path(id: company.id)

      post campaign_display_templates_path, params: {
        campaign_display_template: { name: "My Template", visible_columns: %w[impressions clicks] }
      }
      expect(response).to redirect_to(ad_campaigns_path(template_id: CampaignDisplayTemplate.last.id))
    end
  end
end
