require "rails_helper"

RSpec.describe "ShippingReminderRules", type: :request do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }

  before { sign_in user }

  describe "GET /shipping_reminder_rules" do
    it "returns success for authorized user" do
      membership = user.membership_for(company)
      membership.update!(permissions: membership.permissions + [ "shipping_reminder_rules" ])
      get shipping_reminder_rules_path
      expect(response).to have_http_status(:success)
    end

    it "redirects unauthorized user" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard])
      sign_in member
      patch switch_company_path(id: company.id)
      get shipping_reminder_rules_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "POST /shipping_reminder_rules" do
    it "creates a new rule" do
      post shipping_reminder_rules_path, params: {
        shipping_reminder_rule: {
          rule_type: "not_delivered",
          country_thresholds: [ { country: "US", days: 14 } ]
        }
      }
      expect(response).to redirect_to(shipping_reminder_rules_path)
      expect(company.shipping_reminder_rules.count).to eq(1)
      rule = company.shipping_reminder_rules.first
      expect(rule.rule_type).to eq("not_delivered")
      expect(rule.country_thresholds).to eq([ { "country" => "US", "days" => "14" } ])
    end

    it "returns unprocessable_entity with invalid params" do
      post shipping_reminder_rules_path, params: {
        shipping_reminder_rule: { rule_type: "invalid" }
      }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "updates existing rule of same type instead of duplicating" do
      create(:shipping_reminder_rule, company: company, rule_type: "not_delivered",
             country_thresholds: [ { "country" => "US", "days" => 7 } ])
      post shipping_reminder_rules_path, params: {
        shipping_reminder_rule: {
          rule_type: "not_delivered",
          country_thresholds: [ { country: "CA", days: 21 } ]
        }
      }
      expect(response).to redirect_to(shipping_reminder_rules_path)
      expect(company.shipping_reminder_rules.where(rule_type: "not_delivered").count).to eq(1)
    end
  end

  describe "PATCH /shipping_reminder_rules/:id" do
    let!(:rule) { create(:shipping_reminder_rule, company: company, rule_type: "not_delivered") }

    it "updates rule country_thresholds" do
      patch shipping_reminder_rule_path(id: rule.id), params: {
        shipping_reminder_rule: {
          country_thresholds: [ { country: "CA", days: 21 } ]
        }
      }
      expect(response).to redirect_to(shipping_reminder_rules_path)
      expect(rule.reload.country_thresholds).to eq([ { "country" => "CA", "days" => "21" } ])
    end

    it "toggles enabled" do
      patch shipping_reminder_rule_path(id: rule.id), params: {
        shipping_reminder_rule: { enabled: false }
      }
      expect(response).to redirect_to(shipping_reminder_rules_path)
      expect(rule.reload.enabled).to be false
    end
  end
end
