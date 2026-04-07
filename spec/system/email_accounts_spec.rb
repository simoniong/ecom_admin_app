require "rails_helper"

RSpec.describe "Email Accounts", type: :system do
  let!(:user) { create(:user) }

  it "shows bind new email button" do
    sign_in_as(user)
    navigate_to_settings_item "Email Accounts"
    expect(page).to have_button("Bind New Email")
  end

  it "shows empty state when no accounts" do
    sign_in_as(user)
    navigate_to_settings_item "Email Accounts"
    expect(page).to have_text("No email accounts linked yet.")
  end

  it "binds email via OAuth and shows in list" do
    sign_in_as(user)
    navigate_to_settings_item "Email Accounts"

    click_button "Bind New Email"
    expect(page).to have_current_path(email_accounts_path, wait: 5)

    expect(page).to have_text("Email account bound successfully.")
    expect(page).to have_text("oauth-test@gmail.com")
    expect(page).to have_text("Connected")
  end

  it "navigates to show page when clicking account" do
    sign_in_as(user)
    navigate_to_settings_item "Email Accounts"

    click_button "Bind New Email"
    expect(page).to have_current_path(email_accounts_path, wait: 5)

    click_link "oauth-test@gmail.com"

    expect(page).to have_text("Access Token")
    expect(page).to have_text("Refresh Token")
    expect(page).to have_text("Connected At")
    expect(page).to have_button("Disconnect")
  end

  it "disconnects account and returns to list" do
    sign_in_as(user)
    navigate_to_settings_item "Email Accounts"

    click_button "Bind New Email"
    expect(page).to have_current_path(email_accounts_path, wait: 5)

    click_link "oauth-test@gmail.com"

    accept_confirm do
      click_button "Disconnect"
    end

    expect(page).to have_text("Email account disconnected successfully.")
    expect(page).to have_text("No email accounts linked yet.")
  end
end
