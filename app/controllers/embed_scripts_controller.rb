# frozen_string_literal: true

class EmbedScriptsController < ActionController::Metal
  def show
    headers['Content-Type'] = 'application/javascript; charset=utf-8'
    headers['Cache-Control'] = 'public, max-age=3600'

    self.response_body = script
    self.status = 200
  end

  private

  def script
    asset_path = pack_path
    file_path = Rails.root.join('public', asset_path.delete_prefix('/'))

    return File.read(file_path) if File.exist?(file_path)

    "document.write('<script src=\"#{asset_path}\"><\\/script>')"
  rescue StandardError => e
    Rails.logger.warn("Embed script unavailable: #{e.message}")

    ''
  end

  def pack_path
    ActionController::Base.helpers.asset_pack_path('embed.js')
  rescue StandardError
    '/packs/embed.js'
  end
end
