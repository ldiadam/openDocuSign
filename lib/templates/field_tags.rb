# frozen_string_literal: true

module Templates
  module FieldTags
    TAG_REGEXP = /\{\{([^{}]+)\}\}/
    DEFAULT_TYPE = 'text'
    TYPE_ALIASES = {
      'multi-select' => 'multiple',
      'multi_select' => 'multiple'
    }.freeze
    ATTRIBUTE_KEYS = %w[
      name type role default required readonly title description option condition options
      width height format min max font font_size font_type color align valign hidden mask
      method price currency pattern
    ].freeze

    Entry = Struct.new(:attributes, :area, keyword_init: true)

    module_function

    def call(pdf_bytes, remove_tags: true, unit_scale: 1.0)
      doc = Pdfium::Document.open_bytes(pdf_bytes)
      pages = []
      entries = []
      redacted = false

      doc.page_count.times do |page_index|
        page = doc.get_page(page_index)

        pages << page

        nodes = page.text_nodes
        text = nodes.map(&:content).join
        rects = []

        text.to_enum(:scan, TAG_REGEXP).each do
          match = Regexp.last_match
          selected = nodes[match.begin(0)...match.end(0)]

          next if selected.blank?

          x = selected.map(&:x).min
          y = selected.map(&:y).min
          width = selected.map(&:endx).max - x
          height = selected.map(&:endy).max - y

          attributes = parse_attributes(match[1])

          width = declared_size(attributes['width'], page.width, unit_scale) || width
          height = declared_size(attributes['height'], page.height, unit_scale) || height

          entries << Entry.new(
            attributes:,
            area: { 'x' => x, 'y' => y, 'w' => width, 'h' => height, 'page' => page_index }
          )

          rects << { 'x' => x, 'y' => y, 'w' => width, 'h' => height, 'color' => 'white' }
        end

        next unless remove_tags && rects.present?

        page.redact(rects)
        redacted = true
      end

      result =
        if redacted
          io = StringIO.new
          doc.save(io)
          io.string
        else
          pdf_bytes
        end

      { entries:, pdf: result }
    ensure
      pages&.each(&:close)
      doc&.close
    end

    def build(entries, submitters: [])
      submitters = ensure_submitters(submitters, entries)

      fields = []
      fields_by_key = {}

      entries.each do |entry|
        attributes = entry.attributes
        type = normalize_type(attributes['type'])
        role = attributes['role'].presence || submitters.first['name']
        name = attributes['name'].presence || generated_name(type, fields)
        key = [name, type, role]

        field = fields_by_key[key]

        unless field
          field = build_field(attributes, name, type, role, submitters)
          field['_condition'] = attributes['condition'] if attributes['condition'].present?

          fields_by_key[key] = field
          fields << field
        end

        add_options(field, attributes)

        area = entry.area.merge('attachment_uuid' => entry.area['attachment_uuid'])

        if (option_value = attributes['option'].presence) && %w[radio multiple].include?(type)
          option = find_or_add_option(field, option_value)
          area['option_uuid'] = option['uuid']
        end

        field['areas'] << area
      end

      apply_conditions(fields)

      [fields, submitters]
    end

    def parse_attributes(raw)
      attributes = {}

      raw.split(';').map(&:strip).reject(&:empty?).each_with_index do |part, index|
        key, value = part.split('=', 2)

        if value.nil?
          attributes['name'] ||= part if index.zero?
        else
          attributes[normalize_key(key)] = value
        end
      end

      attributes
    end

    def normalize_key(key)
      key.strip.downcase.tr('-', '_')
    end

    def normalize_type(value)
      type = value.to_s.strip.downcase.presence || DEFAULT_TYPE

      TYPE_ALIASES.fetch(type, type)
    end

    def declared_size(value, page_size, unit_scale)
      size = value.to_f

      return unless size.positive? && page_size.to_f.positive?

      size * unit_scale / page_size
    end

    def build_field(attributes, name, type, role, submitters)
      field = {
        'uuid' => SecureRandom.uuid,
        'submitter_uuid' => submitter_uuid_for(role, submitters),
        'name' => name,
        'type' => type,
        'required' => required?(attributes, type),
        'readonly' => readonly?(attributes, type),
        'preferences' => build_preferences(attributes),
        'options' => build_options(attributes['options']),
        'areas' => []
      }

      field['title'] = attributes['title'] if attributes['title'].present?
      field['description'] = attributes['description'] if attributes['description'].present?
      field['default_value'] = attributes['default'] if attributes['default'].present?

      validation = build_validation(attributes)
      field['validation'] = validation if validation.present?

      field
    end

    def build_preferences(attributes)
      preferences = {}

      %w[format font font_type color align valign method].each do |key|
        preferences[key] = attributes[key] if attributes[key].present?
      end

      preferences['font_size'] = attributes['font_size'].to_f if attributes['font_size'].present?
      preferences['mask'] = true if attributes['mask'] == 'true'
      preferences['hidden'] = true if attributes['hidden'] == 'true'
      preferences['price'] = attributes['price'] if attributes['price'].present?
      preferences['currency'] = attributes['currency'].upcase if attributes['currency'].present?

      preferences
    end

    def build_validation(attributes)
      validation = {}

      validation['pattern'] = attributes['pattern'] if attributes['pattern'].present?
      validation['min'] = attributes['min'] if attributes['min'].present?
      validation['max'] = attributes['max'] if attributes['max'].present?

      validation
    end

    def build_options(value)
      value.to_s.split(',').map(&:strip).reject(&:blank?).map do |option|
        { 'uuid' => SecureRandom.uuid, 'value' => option }
      end
    end

    def add_options(field, attributes)
      return unless attributes['options'].present?

      build_options(attributes['options']).each do |option|
        next if field['options'].any? { |item| item['value'] == option['value'] }

        field['options'] << option
      end
    end

    def find_or_add_option(field, value)
      option = field['options'].find { |item| item['value'] == value }

      return option if option

      option = { 'uuid' => SecureRandom.uuid, 'value' => value }
      field['options'] << option
      option
    end

    def required?(attributes, type)
      return true if %w[phone verification kba].include?(type)

      attributes['required'].to_s != 'false'
    end

    def readonly?(attributes, type)
      return true if %w[datenow stamp].include?(type)

      attributes['readonly'].to_s == 'true'
    end

    def submitter_uuid_for(role, submitters)
      submitters.find { |submitter| submitter['name'] == role }&.fetch('uuid')
    end

    def ensure_submitters(submitters, entries)
      submitters = Array(submitters).map do |submitter|
        submitter.respond_to?(:to_h) ? submitter.to_h.stringify_keys : submitter
      end

      roles = entries.filter_map { |entry| entry.attributes['role'].presence }.uniq

      if submitters.empty? && roles.empty?
        submitters << { 'name' => Template::DEFAULT_SUBMITTER_NAME, 'uuid' => SecureRandom.uuid }
      end

      roles.each do |role|
        next if submitters.any? { |submitter| submitter['name'] == role }

        submitters << { 'name' => role, 'uuid' => SecureRandom.uuid }
      end

      submitters
    end

    def generated_name(type, fields)
      base = type == 'stamp' ? 'Stamp' : type.titleize
      index = fields.count { |field| field['name'].to_s.start_with?(base) } + 1

      "#{base} #{index}"
    end

    def apply_conditions(fields)
      fields.each do |field|
        condition = field.delete('_condition')

        next if condition.blank?

        name, value = condition.split(':', 2)
        target = fields.find { |item| item['name'].to_s.casecmp?(name.to_s.strip) }

        next unless target

        action, condition_value = condition_action(target, value)

        field['conditions'] = [{
          'field_uuid' => target['uuid'],
          'action' => action,
          'value' => condition_value,
          'operation' => 'and'
        }].compact
      end
    end

    def condition_action(target, value)
      if target['type'] == 'checkbox'
        return ['checked', nil] if value == 'true'
        return ['unchecked', nil] if value == 'false'

        ['not_empty', nil]
      elsif value.blank?
        ['not_empty', nil]
      elsif %w[radio select multiple].include?(target['type'])
        option = target['options'].find { |item| item['value'] == value }

        ['equal', option ? option['uuid'] : value]
      else
        ['equal', value]
      end
    end
  end
end
