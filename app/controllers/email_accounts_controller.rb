class EmailAccountsController < AdminController
  def index
    @email_accounts = current_user.email_accounts.order(created_at: :desc)
  end
end
