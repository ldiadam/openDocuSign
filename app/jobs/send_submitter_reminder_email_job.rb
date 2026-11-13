# frozen_string_literal: true

class SendSubmitterReminderEmailJob
  include Sidekiq::Job

  sidekiq_options retry: 3

  def perform(params = {})
    submitter = Submitter.find(params['submitter_id'])

    return if submitter.completed_at?
    return if submitter.declined_at?
    return if submitter.viewer?
    return if submitter.email.blank?
    return if submitter.preferences['send_email'] == false
    return if submitter.submission.archived_at?
    return if submitter.submission.expired?
    return if submitter.template&.archived_at?

    return unless Accounts.can_send_emails?(submitter.account)
    return unless Accounts.can_send_invitation_emails?(submitter.account)

    mail = SubmitterMailer.invitation_reminder_email(submitter)

    Submitters::ValidateSending.call(submitter, mail)

    mail.deliver_now!

    SubmissionEvent.create!(submitter:, event_type: 'send_reminder_email')
  end
end
