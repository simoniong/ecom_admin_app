require "rails_helper"

RSpec.describe "CampaignDisplayTemplates", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "POST /campaign_display_templates" do
    it "creates a template" do
      sign_in user
      expect {
        post campaign_display_templates_path, params: {
          campaign_display_template: { name: "My Template", visible_columns: %w[impressions clicks spend] }
        }
      }.to change(CampaignDisplayTemplate, :count).by(1)

      template = user.campaign_display_templates.last
      expect(template.name).to eq("My Template")
      expect(template.visible_columns).to eq(%w[impressions clicks spend])
      expect(template.last_active_at).to be_present
      expect(response).to redirect_to(ad_campaigns_path(template_id: template.id))
    end

    it "redirects with alert on invalid params" do
      sign_in user
      post campaign_display_templates_path, params: {
        campaign_display_template: { name: "", visible_columns: [] }
      }
      expect(response).to redirect_to(ad_campaigns_path)
      expect(flash[:alert]).to be_present
    end

    it "redirects unauthenticated user" do
      post campaign_display_templates_path, params: {
        campaign_display_template: { name: "Test", visible_columns: %w[clicks] }
      }
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "PATCH /campaign_display_templates/:id" do
    it "updates a template" do
      template = create(:campaign_display_template, user: user, name: "Old Name")
      sign_in user
      patch campaign_display_template_path(id: template.id), params: {
        campaign_display_template: { name: "New Name", visible_columns: %w[roas spend] }
      }
      template.reload
      expect(template.name).to eq("New Name")
      expect(template.visible_columns).to eq(%w[roas spend])
      expect(response).to redirect_to(ad_campaigns_path(template_id: template.id))
    end

    it "returns 404 for another user's template" do
      template = create(:campaign_display_template, user: other_user)
      sign_in user
      patch campaign_display_template_path(id: template.id), params: {
        campaign_display_template: { name: "Hacked" }
      }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /campaign_display_templates/:id" do
    it "deletes a template" do
      template = create(:campaign_display_template, user: user)
      sign_in user
      expect {
        delete campaign_display_template_path(id: template.id)
      }.to change(CampaignDisplayTemplate, :count).by(-1)
      expect(response).to redirect_to(ad_campaigns_path)
    end

    it "returns 404 for another user's template" do
      template = create(:campaign_display_template, user: other_user)
      sign_in user
      delete campaign_display_template_path(id: template.id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
