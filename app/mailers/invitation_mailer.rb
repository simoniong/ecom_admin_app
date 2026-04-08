class InvitationMailer < ApplicationMailer
  def invite(invitation)
    @invitation = invitation
    @accept_url = accept_invitation_url(token: invitation.token)
    mail(to: invitation.email, subject: t("invitations.email_subject", company: invitation.company.name))
  end
end
