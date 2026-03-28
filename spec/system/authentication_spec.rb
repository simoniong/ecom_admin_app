require "rails_helper"

RSpec.describe "Authentication", type: :system do
  let!(:user) { create(:user) }

  it "shows login form at root" do
    visit root_path
    expect(page).to have_selector("h2", text: "Sign in")
    expect(page).to have_selector("input[type='email']")
    expect(page).to have_selector("input[type='password']")
  end

  it "shows dashboard with sidebar after login" do
    sign_in_via_form(user)

    expect(page).to have_text("Dashboard")
    expect(page).to have_text("Welcome back")
    expect(page).to have_selector("aside")
    expect(page).to have_link("Email Accounts")
    expect(page).to have_link("Tickets")
  end

  it "shows user email on page" do
    sign_in_as(user)

    expect(page).to have_text(user.email)
  end

  it "navigates to email accounts page" do
    sign_in_as(user)
    click_link "Email Accounts"
    expect(page).to have_text("Email Accounts")
    expect(page).to have_text("No email accounts linked yet.")
  end

  it "navigates to tickets page" do
    sign_in_as(user)
    click_link "Tickets"
    expect(page).to have_text("Tickets")
    expect(page).to have_text("New")
    expect(page).to have_text("Draft")
  end

  it "logs out and redirects to login" do
    sign_in_as(user)
    click_button "Sign out"
    expect(page).to have_selector("h2", text: "Sign in")
  end

  it "shows error on wrong password" do
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "wrongpassword"
    click_button "Sign in"

    expect(page).to have_text("Invalid email or password.")
  end
end
