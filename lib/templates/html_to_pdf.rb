# frozen_string_literal: true

module Templates
  module HtmlToPdf
    Error = Class.new(StandardError)

    FIELD_TAGS = {
      'text-field' => 'text',
      'signature-field' => 'signature',
      'initials-field' => 'initials',
      'date-field' => 'date',
      'datenow-field' => 'datenow',
      'image-field' => 'image',
      'file-field' => 'file',
      'checkbox-field' => 'checkbox',
      'radio-field' => 'radio',
      'select-field' => 'select',
      'multi-select-field' => 'multiple',
      'payment-field' => 'payment',
      'phone-field' => 'phone',
      'verification-field' => 'verification',
      'kba-field' => 'kba',
      'stamp-field' => 'stamp',
      'number-field' => 'number',
      'cells-field' => 'cells',
      'heading-field' => 'heading',
      'strikethrough-field' => 'strikethrough'
    }.freeze

    FIELD_ATTRIBUTES = %w[
      role default required readonly title description option condition options pattern format
      min max font font-size font-type color align valign mask method price currency
    ].freeze

    PAPER_FORMATS = {
      'Letter' => :letter,
      'Legal' => :legal,
      'Tabloid' => :tabloid,
      'Ledger' => :ledger,
      'A0' => :A0,
      'A1' => :A1,
      'A2' => :A2,
      'A3' => :A3,
      'A4' => :A4,
      'A5' => :A5,
      'A6' => :A6
    }.freeze

    CHROME_BIN = ENV.fetch('CHROME_BIN', '/usr/bin/chromium-browser')
    CHROME_OPTIONS = {
      'no-sandbox' => nil,
      'disable-dev-shm-usage' => nil,
      'disable-gpu' => nil,
      'disable-vulkan' => nil,
      'headless' => 'new'
    }.freeze

    module_function

    def call(html, html_header: nil, html_footer: nil, size: 'Letter')
      document = parse(html)
      body = document.at_css('body') || document.root

      raise Error, 'HTML document has no body' if body.nil?

      transform_fields(document)

      render(
        document.to_html,
        header: template_html(html_header),
        footer: template_html(html_footer),
        size:
      )
    end

    def parse(html)
      if defined?(Nokogiri::HTML5)
        Nokogiri::HTML5.parse(html.to_s)
      else
        Nokogiri::HTML.parse(html.to_s)
      end
    rescue StandardError => e
      raise Error, "Invalid HTML: #{e.message}"
    end

    def transform_fields(document)
      FIELD_TAGS.each do |tag_name, type|
        document.css(tag_name).each do |element|
          style = element['style'].to_s
          default_size = %w[signature initials stamp image].include?(type) ? %w[160 40] : %w[120 20]
          width = style[/width:\s*([\d.]+)px/i, 1] || default_size[0]
          height = style[/height:\s*([\d.]+)px/i, 1] || default_size[1]

          outer = Nokogiri::XML::Node.new('span', document)
          outer['class'] = 'docuseal-field-tag-box'
          outer['style'] = [
            style,
            "width: #{width}px",
            "height: #{height}px",
            'display: inline-block',
            'position: relative'
          ].compact.join('; ')

          inner = Nokogiri::XML::Node.new('span', document)
          inner['class'] = 'docuseal-field-tag'
          inner['style'] = [
            'position: absolute',
            'left: 0',
            'bottom: 0',
            'overflow: visible',
            'white-space: nowrap',
            'color: #ffffff',
            'font-size: 4px',
            'line-height: 1'
          ].join('; ')
          inner.content = "{{#{build_tag(element, type, width, height)}}}"

          outer.add_child(inner)
          element.replace(outer)
        end
      end
    end

    def build_tag(element, type, width, height)
      parts = []

      parts << element['name'] if element['name'].present?
      parts << "type=#{type}"

      FIELD_ATTRIBUTES.each do |attribute|
        value = element[attribute]

        parts << "#{attribute}=#{value}" if value.present?
      end

      parts << "width=#{width}"
      parts << "height=#{height}"

      parts.join(';')
    end

    def template_html(html)
      return if html.blank?

      fragment = if defined?(Nokogiri::HTML5)
                   Nokogiri::HTML5.fragment(html.to_s)
                 else
                   Nokogiri::HTML.fragment(html.to_s)
                 end

      styles = fragment.css('style').map(&:to_html).join
      body = fragment.at_css('body')
      content = body ? body.inner_html : fragment.to_html

      "#{styles}#{content}"
    rescue StandardError
      html.to_s
    end

    def render(html, header:, footer:, size:)
      require 'base64'
      require 'ferrum'

      browser = nil

      begin
        browser = Ferrum::Browser.new(
          browser_path: CHROME_BIN,
          headless: false,
          timeout: 30,
          process_timeout: 30,
          browser_options: CHROME_OPTIONS
        )

        page = browser.create_page
        page.content = html

        begin
          page.network.wait_for_idle(timeout: 5) if page.network.respond_to?(:wait_for_idle)
        rescue StandardError
          nil
        end

        options = {
          format: PAPER_FORMATS.fetch(size.to_s, :letter),
          print_background: true,
          prefer_css_page_size: false,
          margin: { top: 0, bottom: 0, left: 0, right: 0 }
        }

        if header.present? || footer.present?
          options[:display_header_footer] = true
          options[:header_template] = header.to_s
          options[:footer_template] = footer.to_s
          options[:margin] = { top: 0.98, bottom: 0.98, left: 0.59, right: 0.59 }
        end

        Base64.decode64(page.pdf(**options))
      rescue LoadError
        raise Error, 'Ferrum is not installed. Add the ferrum gem to run the HTML API.'
      rescue StandardError => e
        raise Error, "HTML rendering failed: #{e.message}"
      ensure
        begin
          browser&.quit
        rescue StandardError
          nil
        end
      end
    end
  end
end
