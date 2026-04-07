require "rails_helper"

RSpec.describe "Authentication", type: :request do
  let(:user) { create(:user) }

  it "shows login page at root for unauthenticated user" do
    get root_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include("Sign in")
  end

  it "allows login with valid credentials" do
    sign_in user
    get authenticated_root_path
    expect(response).to have_http_status(:success)
  end

  it "logs in via form with valid credentials" do
    post user_session_path, params: {
      user: { email: user.email, password: user.password }
    }
    expect(response).to redirect_to(authenticated_root_path)
  end

  it "rejects login with invalid credentials" do
    post user_session_path, params: {
      user: { email: user.email, password: "wrongpassword" }
    }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "logs out and redirects to login" do
    sign_in user
    delete destroy_user_session_path
    expect(response).to redirect_to(root_path)
  end

  it "allows authenticated user to access email accounts" do
    sign_in user
    get email_accounts_path
    expect(response).to have_http_status(:success)
  end

  it "allows authenticated user to access tickets" do
    sign_in user
    get tickets_path
    expect(response).to have_http_status(:success)
  end

  it "redirects unauthenticated user from email accounts" do
    get email_accounts_path
    expect(response).to redirect_to(new_user_session_path)
  end

  it "redirects unauthenticated user from tickets" do
    get tickets_path
    expect(response).to redirect_to(new_user_session_path)
  end

  it "locks account after maximum failed attempts" do
    Devise.maximum_attempts.times do
      post user_session_path, params: {
        user: { email: user.email, password: "wrongpassword" }
      }
    end

    post user_session_path, params: {
      user: { email: user.email, password: user.password }
    }
    expect(response).to have_http_status(:unprocessable_content)
  end
end
