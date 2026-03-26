require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#parse_email_address" do
    it "extracts email from angle brackets" do
      expect(helper.parse_email_address("John Doe <john@example.com>")).to eq("john@example.com")
    end

    it "returns plain email as-is" do
      expect(helper.parse_email_address("john@example.com")).to eq("john@example.com")
    end

    it "returns nil for blank input" do
      expect(helper.parse_email_address(nil)).to be_nil
      expect(helper.parse_email_address("")).to be_nil
    end
  end

  describe "#split_email_body" do
    it "returns body as new content when no quotes" do
      body = "Hello, I need help with my order."
      new_content, quoted = helper.split_email_body(body)
      expect(new_content).to eq("Hello, I need help with my order.")
      expect(quoted).to be_nil
    end

    it "splits on 'On ... wrote:' pattern" do
      body = "Thanks for the update.\n\nOn Mon, Mar 25, 2026, John wrote:\n> Original message here\n> More original"
      new_content, quoted = helper.split_email_body(body)
      expect(new_content).to eq("Thanks for the update.")
      expect(quoted).to include("On Mon, Mar 25, 2026, John wrote:")
      expect(quoted).to include("> Original message here")
    end

    it "splits on quoted lines starting with >" do
      body = "My reply here.\n\n> Previous message line 1\n> Previous message line 2"
      new_content, quoted = helper.split_email_body(body)
      expect(new_content).to eq("My reply here.")
      expect(quoted).to include("> Previous message line 1")
    end

    it "handles blank body" do
      new_content, quoted = helper.split_email_body(nil)
      expect(new_content).to be_nil
      expect(quoted).to be_nil
    end

    it "handles body with only quoted content" do
      body = "> Quoted line 1\n> Quoted line 2\n> Quoted line 3"
      new_content, quoted = helper.split_email_body(body)
      expect(new_content).to eq("")
      expect(quoted).to include("> Quoted line 1")
    end

    it "ignores a single > that is not a quote block" do
      body = "The price is > $50.\nThat's too much."
      new_content, quoted = helper.split_email_body(body)
      expect(new_content).to eq("The price is > $50.\nThat's too much.")
      expect(quoted).to be_nil
    end
  end
end
