require "rails_helper"

RSpec.describe InvitationMailer, type: :mailer do
  describe "#invite" do
    let(:owner) { create(:user) }
    let(:company) { owner.companies.first }
    let(:invitation) { create(:invitation, company: company, invited_by: owner, email: "newbie@example.com") }
    let(:mail) { described_class.invite(invitation) }

    it "renders the headers" do
      expect(mail.to).to eq(%w[newbie@example.com])
      expect(mail.subject).to include(company.name)
    end

    it "renders the body with accept link" do
      expect(mail.body.encoded).to include(accept_invitation_url(token: invitation.token))
    end

    it "mentions the inviter" do
      expect(mail.body.encoded).to include(owner.email)
    end
  end
end
