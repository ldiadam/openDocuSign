# frozen_string_literal: true

class PersonalizationLogosController < ApplicationController
  ALLOWED_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
  MAX_FILE_SIZE = 2.megabytes

  def create
    authorize!(:manage, current_account)

    logo = params[:logo]

    unless valid_logo?(logo)
      return redirect_back fallback_location: settings_personalization_path, alert: I18n.t('unable_to_save')
    end

    current_account.logo.purge if current_account.logo.attached?
    current_account.logo.attach(logo)

    redirect_back fallback_location: settings_personalization_path, notice: I18n.t('changes_have_been_saved')
  end

  def destroy
    authorize!(:manage, current_account)

    current_account.logo.purge

    redirect_back fallback_location: settings_personalization_path, notice: I18n.t('changes_have_been_saved')
  end

  private

  def valid_logo?(logo)
    logo.is_a?(ActionDispatch::Http::UploadedFile) &&
      logo.content_type.in?(ALLOWED_CONTENT_TYPES) &&
      logo.size.to_i.positive? &&
      logo.size <= MAX_FILE_SIZE
  end
end
