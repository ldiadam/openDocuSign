# frozen_string_literal: true

module Embeddable
  def default_url_options
    super.merge(embed_mode? ? { embed: true } : {})
  end
end
