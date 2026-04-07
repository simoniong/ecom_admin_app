require "rails_helper"

RSpec.describe "Passwords", type: :request do
  let(:user) { create(:user) }

  describe "GET /users/password/new" do
    it "returns 200" do
      get new_user_password_path
      expect(response).to have_http_status(:success)
    end
  end

  describe "POST /users/password" do
    it "sends reset instructions for valid email" do
      post user_password_path, params: { user: { email: user.email } }
      expect(response).to redirect_to(new_user_session_path)
      follow_redirect!
      expect(response.body).to include("You will receive an email with instructions")
    end

    it "returns error for invalid email when not in paranoid mode" do
      post user_password_path, params: { user: { email: "nonexistent@example.com" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /users/password/edit" do
    it "returns 200 with valid token" do
      raw_token = user.send_reset_password_instructions
      get edit_user_password_path(reset_password_token: raw_token)
      expect(response).to have_http_status(:success)
    end
  end

  describe "PUT /users/password" do
    it "resets password with valid token and matching passwords" do
      raw_token = user.send_reset_password_instructions
      put user_password_path, params: {
        user: {
          reset_password_token: raw_token,
          password: "newpassword123",
          password_confirmation: "newpassword123"
        }
      }
      expect(response).to redirect_to(authenticated_root_path)
      user.reload
      expect(user.valid_password?("newpassword123")).to be true
    end
  end
end
