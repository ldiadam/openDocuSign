# frozen_string_literal: true

# Allow signing pages to be embedded in iframes.
# X-Frame-Options cannot express more than one origin and conflicts with
# CSP frame-ancestors, so remove it and rely on the CSP directive.
Rails.application.config.action_dispatch.default_headers =
  Rails.application.config.action_dispatch.default_headers.except('X-Frame-Options')
