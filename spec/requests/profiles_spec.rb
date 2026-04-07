require "rails_helper"

RSpec.describe "Profiles", type: :request do
  let(:user) { create(:user) }

  describe "unauthenticated access" do
    it "redirects to login" do
      get edit_profile_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /profile/edit" do
    it "returns 200 for authenticated user" do
      sign_in user
      get edit_profile_path
      expect(response).to have_http_status(:success)
    end
  end

  describe "PATCH /profile" do
    before { sign_in user }

    it "updates first_name and last_name" do
      patch profile_path, params: { user: { first_name: "John", last_name: "Doe" } }
      expect(response).to redirect_to(edit_profile_path)
      user.reload
      expect(user.first_name).to eq("John")
      expect(user.last_name).to eq("Doe")
    end

    it "changes password with valid current_password" do
      patch profile_path, params: {
        user: {
          first_name: "John",
          last_name: "Doe",
          current_password: "password123",
          password: "newpassword456",
          password_confirmation: "newpassword456"
        }
      }
      expect(response).to redirect_to(edit_profile_path)
      user.reload
      expect(user.valid_password?("newpassword456")).to be true
    end

    it "fails with wrong current_password" do
      patch profile_path, params: {
        user: {
          first_name: "John",
          last_name: "Doe",
          current_password: "wrongpassword",
          password: "newpassword456",
          password_confirmation: "newpassword456"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "fails with mismatched password/confirmation" do
      patch profile_path, params: {
        user: {
          first_name: "John",
          last_name: "Doe",
          current_password: "password123",
          password: "newpassword456",
          password_confirmation: "differentpassword"
        }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
