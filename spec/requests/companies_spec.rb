require "rails_helper"

RSpec.describe "Companies", type: :request do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }
  let(:valid_key) { "A" * 32 }
  let(:alt_key) { "B" * 32 }

  describe "GET /company/edit" do
    it "returns success for owner" do
      sign_in user
      get edit_company_path
      expect(response).to have_http_status(:success)
    end

    it "redirects member to root" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard])
      sign_in member
      patch switch_company_path(id: company.id)
      get edit_company_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "PATCH /company" do
    it "updates company name for owner" do
      sign_in user
      patch company_path, params: { company: { name: "New Name" } }
      expect(response).to redirect_to(edit_company_path)
      expect(company.reload.name).to eq("New Name")
    end

    it "rejects blank name" do
      sign_in user
      patch company_path, params: { company: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "redirects member" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard])
      sign_in member
      patch switch_company_path(id: company.id)
      patch company_path, params: { company: { name: "Hack" } }
      expect(response).to redirect_to(authenticated_root_path)
      expect(company.reload.name).not_to eq("Hack")
    end

    it "enables tracking with new_only mode when toggle + key + mode are supplied" do
      sign_in user
      freeze_time do
        patch tracking_company_path, params: {
          company: { tracking_enabled: "1", tracking_api_key: valid_key, tracking_mode: "new_only" }
        }
        expect(response).to redirect_to(edit_company_path)
        company.reload
        expect(company.tracking_enabled?).to be(true)
        expect(company.tracking_api_key).to eq(valid_key)
        expect(company.tracking_mode).to eq("new_only")
        expect(company.tracking_starts_at).to eq(Time.current)
      end
    end

    it "enables tracking with backfill mode defaulting to 30 days" do
      sign_in user
      freeze_time do
        patch tracking_company_path, params: {
          company: { tracking_enabled: "1", tracking_api_key: valid_key, tracking_mode: "backfill" }
        }
        company.reload
        expect(company.tracking_enabled?).to be(true)
        expect(company.tracking_mode).to eq("backfill")
        expect(company.tracking_backfill_days).to eq(30)
        expect(company.tracking_starts_at).to eq(30.days.ago)
      end
    end

    it "saves a custom backfill days value" do
      sign_in user
      freeze_time do
        patch tracking_company_path, params: {
          company: { tracking_enabled: "1", tracking_api_key: valid_key, tracking_mode: "backfill", tracking_backfill_days: "90" }
        }
        company.reload
        expect(company.tracking_backfill_days).to eq(90)
        expect(company.tracking_starts_at).to eq(90.days.ago)
      end
    end

    it "saves all-history tracking (nil days, nil starts_at) when the checkbox is set" do
      sign_in user
      patch tracking_company_path, params: {
        company: {
          tracking_enabled: "1",
          tracking_api_key: valid_key,
          tracking_mode: "backfill",
          tracking_backfill_days: "30",
          tracking_backfill_all: "1"
        }
      }
      company.reload
      expect(company.tracking_mode).to eq("backfill")
      expect(company.tracking_backfill_days).to be_nil
      expect(company.tracking_starts_at).to be_nil
      expect(company.tracking_all_history?).to be(true)
    end

    it "ignores backfill_days when mode is new_only" do
      sign_in user
      freeze_time do
        patch tracking_company_path, params: {
          company: { tracking_enabled: "1", tracking_api_key: valid_key, tracking_mode: "new_only", tracking_backfill_days: "90" }
        }
        company.reload
        expect(company.tracking_backfill_days).to be_nil
        expect(company.tracking_starts_at).to eq(Time.current)
      end
    end

    it "rejects enabling without an api key (unconfigured)" do
      sign_in user
      patch tracking_company_path, params: { company: { tracking_enabled: "1" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("activerecord.errors.models.company.attributes.tracking_api_key.required_when_enabled"))
      company.reload
      expect(company.tracking_enabled?).to be(false)
      expect(company.tracking_api_key).to be_nil
    end

    it "rejects enabling with an api key but no mode" do
      sign_in user
      patch tracking_company_path, params: {
        company: { tracking_enabled: "1", tracking_api_key: valid_key, tracking_mode: "" }
      }
      expect(response).to have_http_status(:unprocessable_content)
      company.reload
      expect(company.tracking_enabled?).to be(false)
      expect(company.tracking_api_key).to be_nil
    end

    it "rejects api keys that are not 32 alphanumeric characters" do
      sign_in user
      patch tracking_company_path, params: {
        company: { tracking_enabled: "1", tracking_api_key: "too-short", tracking_mode: "new_only" }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("activerecord.errors.models.company.attributes.tracking_api_key.invalid_format"))
      expect(company.reload.tracking_api_key).to be_nil
    end

    it "keeps existing config when toggling off (disable preserves data)" do
      company.update!(
        tracking_enabled: true,
        tracking_api_key: valid_key,
        tracking_mode: "backfill",
        tracking_backfill_days: 60,
        tracking_starts_at: 60.days.ago
      )
      sign_in user

      patch tracking_company_path, params: { company: { tracking_enabled: "0" } }

      company.reload
      expect(company.tracking_enabled?).to be(false)
      expect(company.tracking_api_key).to eq(valid_key)
      expect(company.tracking_mode).to eq("backfill")
      expect(company.tracking_backfill_days).to eq(60)
      expect(company.tracking_starts_at.to_i).to eq(60.days.ago.to_i)
    end

    it "re-enables with existing config without requiring a new key" do
      original_starts_at = 10.days.ago
      company.update!(
        tracking_enabled: false,
        tracking_api_key: valid_key,
        tracking_mode: "new_only",
        tracking_starts_at: original_starts_at
      )
      sign_in user

      patch tracking_company_path, params: { company: { tracking_enabled: "1" } }

      company.reload
      expect(company.tracking_enabled?).to be(true)
      expect(company.tracking_api_key).to eq(valid_key)
      expect(company.tracking_starts_at.to_i).to eq(original_starts_at.to_i)
    end

    it "locks mode/days when enabled and api key field is left blank" do
      company.update!(
        tracking_enabled: true,
        tracking_api_key: valid_key,
        tracking_mode: "backfill",
        tracking_backfill_days: 60,
        tracking_starts_at: 60.days.ago
      )
      sign_in user

      patch tracking_company_path, params: {
        company: {
          tracking_enabled: "1",
          tracking_api_key: "",
          tracking_mode: "new_only",
          tracking_backfill_days: "10"
        }
      }

      company.reload
      expect(company.tracking_api_key).to eq(valid_key)
      expect(company.tracking_mode).to eq("backfill")
      expect(company.tracking_backfill_days).to eq(60)
    end

    it "allows changing mode and days when providing a new api key" do
      company.update!(
        tracking_enabled: true,
        tracking_api_key: valid_key,
        tracking_mode: "new_only",
        tracking_starts_at: 10.days.ago
      )
      sign_in user

      freeze_time do
        patch tracking_company_path, params: {
          company: { tracking_enabled: "1", tracking_api_key: alt_key, tracking_mode: "backfill", tracking_backfill_days: "45" }
        }
        company.reload
        expect(company.tracking_api_key).to eq(alt_key)
        expect(company.tracking_mode).to eq("backfill")
        expect(company.tracking_backfill_days).to eq(45)
        expect(company.tracking_starts_at).to eq(45.days.ago)
      end
    end
  end
end
