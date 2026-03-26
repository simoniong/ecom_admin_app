class SyncGmailThreadsJob < ApplicationJob
  queue_as :default

  def perform
    EmailAccount.find_each do |email_account|
      GmailSyncService.new(email_account).sync!
    rescue => e
      Rails.logger.error("[GmailSync] Failed for EmailAccount##{email_account.id}: #{e.message}")
    end
  end
end
