require "rails_helper"

RSpec.describe EmailWorkflowStep, type: :model do
  let(:workflow) { create(:email_workflow) }
  let(:step) { create(:email_workflow_step, email_workflow: workflow) }

  it "is valid with valid attributes" do
    expect(step).to be_valid
  end

  it "belongs to email_workflow" do
    expect(step.email_workflow).to eq(workflow)
  end

  it "requires step_type" do
    step.step_type = nil
    expect(step).not_to be_valid
  end

  it "validates step_type inclusion" do
    step.step_type = "invalid"
    expect(step).not_to be_valid
  end

  it "accepts valid step_types" do
    %w[delay send_email].each do |type|
      step.step_type = type
      expect(step).to be_valid
    end
  end

  it "requires position" do
    step.position = nil
    expect(step).not_to be_valid
  end

  it "rejects negative position" do
    step.position = -1
    expect(step).not_to be_valid
  end

  describe "#delay?" do
    it "returns true for delay step" do
      step.step_type = "delay"
      expect(step.delay?).to be true
    end

    it "returns false for send_email step" do
      step.step_type = "send_email"
      expect(step.delay?).to be false
    end
  end

  describe "#send_email?" do
    it "returns true for send_email step" do
      step.step_type = "send_email"
      expect(step.send_email?).to be true
    end
  end

  describe "#summary" do
    it "returns delay summary for delay steps" do
      step.step_type = "delay"
      step.config = { "amount" => 2, "unit" => "days" }
      expect(step.summary).to include("Wait 2 Days")
    end

    it "includes until_time in delay summary" do
      step.step_type = "delay"
      step.config = { "amount" => 1, "unit" => "hours", "until_time" => "09:00" }
      expect(step.summary).to include("09:00")
    end

    it "returns truncated instruction for send_email steps" do
      step.step_type = "send_email"
      step.config = { "instruction" => "A" * 100 }
      expect(step.summary.length).to be <= 60
    end
  end
end
