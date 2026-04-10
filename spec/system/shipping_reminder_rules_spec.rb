require "rails_helper"

RSpec.describe "Shipping Reminder Rules", type: :system do
  let!(:user) { create(:user) }

  before do
    membership = user.membership_for(user.companies.first)
    membership.update!(permissions: membership.permissions + [ "shipping_reminder_rules" ])
  end

  it "shows the reminder rules page" do
    sign_in_as(user)
    navigate_to_settings_item "Shipping Reminders"
    expect(page).to have_text("Reminder Rules")
    expect(page).to have_text("Not delivered for over X days")
    expect(page).to have_text("Without updates for over X days")
    expect(page).to have_text("Ready for Pickup for over X days")
    expect(page).to have_text("Tracking stopped")
  end

  it "expands an accordion and adds a country/days item" do
    sign_in_as(user)
    navigate_to_settings_item "Shipping Reminders"

    click_button "Rule: Not delivered for over X days"

    first("[data-action='click->threshold-items#add']").click
    expect(page).to have_selector("[data-threshold-row]", count: 1)
  end

  it "saves a reminder rule with country thresholds" do
    sign_in_as(user)
    navigate_to_settings_item "Shipping Reminders"

    click_button "Rule: Not delivered for over X days"
    first("[data-action='click->threshold-items#add']").click

    within(first("[data-threshold-row]")) do
      select "United States of America", from: "shipping_reminder_rule[country_thresholds][][country]"
      fill_in name: "shipping_reminder_rule[country_thresholds][][days]", with: "14"
    end

    click_button "Save", match: :first
    expect(page).to have_text("Reminder rule updated successfully.")
  end

  it "toggles email reminder on via switch" do
    sign_in_as(user)
    navigate_to_settings_item "Shipping Reminders"

    expect(page).to have_text("Off")
    find("form[action*='toggle'] button[type='submit']").click
    expect(page).to have_text("Email reminder turned on.")
    expect(page).to have_text("On")
  end

  it "edits recipients inline" do
    sign_in_as(user)
    navigate_to_settings_item "Shipping Reminders"

    find("[data-action='click->inline-edit#edit']").click

    within("[data-inline-edit-target='editor']") do
      fill_in "shipping_reminder_setting[recipients_text]", with: "admin@example.com"
      click_button "Save"
    end

    expect(page).to have_text("Email reminder settings updated successfully.")
    expect(page).to have_text("admin@example.com")
  end

  it "configures email schedule settings" do
    sign_in_as(user)
    navigate_to_settings_item "Shipping Reminders"

    click_button "Save Settings"
    expect(page).to have_text("Email reminder settings updated successfully.")
  end

  it "shows day-of-week selector only when weekly is selected" do
    sign_in_as(user)
    navigate_to_settings_item "Shipping Reminders"

    # Day selector not visible by default (daily)
    expect(page).to have_no_select("shipping_reminder_setting[send_day_of_week]", visible: :visible)

    # Select weekly — day selector becomes visible
    choose "Every week"
    expect(page).to have_select("shipping_reminder_setting[send_day_of_week]", visible: :visible)
  end
end
