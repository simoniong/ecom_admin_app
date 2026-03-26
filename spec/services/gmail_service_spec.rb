require "rails_helper"

RSpec.describe GmailService do
  let(:email_account) { create(:email_account, token_expires_at: 1.hour.from_now) }
  let(:service) { described_class.new(email_account) }

  describe "#token_expired?" do
    it "returns false when token is not expired" do
      expect(service.send(:token_expired?)).to be false
    end

    it "returns true when token_expires_at is nil" do
      email_account.update!(token_expires_at: nil)
      expect(service.send(:token_expired?)).to be true
    end

    it "returns true when token expires within 5 minutes" do
      email_account.update!(token_expires_at: 3.minutes.from_now)
      expect(service.send(:token_expired?)).to be true
    end
  end

  describe "#refresh_token_if_needed!" do
    it "refreshes token when expired" do
      email_account.update!(token_expires_at: 1.minute.ago)

      stub_request(:post, GmailService::GOOGLE_TOKEN_URI)
        .to_return(
          status: 200,
          body: { access_token: "new-token", expires_in: 3600 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      service.send(:refresh_token_if_needed!)

      email_account.reload
      expect(email_account.access_token).to eq("new-token")
      expect(email_account.token_expires_at).to be > Time.current
    end

    it "raises on refresh failure" do
      email_account.update!(token_expires_at: 1.minute.ago)

      stub_request(:post, GmailService::GOOGLE_TOKEN_URI)
        .to_return(
          status: 401,
          body: { error: "invalid_grant" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect { service.send(:refresh_token_if_needed!) }.to raise_error(RuntimeError, /Token refresh failed/)
    end

    it "does not refresh when token is valid" do
      expect(service.send(:refresh_token_if_needed!)).to be_nil
    end
  end
end
