# frozen_string_literal: true

module Api
  class TemplatesController < ApiBaseController
    CreationError = Class.new(StandardError)

    load_and_authorize_resource :template, except: %i[pdf docx]
    before_action :build_template, only: %i[pdf docx]

    rescue_from CreationError, Templates::CreateAttachments::InvalidFileType,
                Templates::CreateAttachments::PdfEncrypted, DownloadUtils::UnableToDownload,
                Pdfium::PdfiumError do |e|
      render json: { error: e.message }, status: :unprocessable_content
    end

    def index
      @templates = Templates.shared(current_user) if params[:shared].in?(['true', true])

      templates = filter_templates(@templates, params)

      templates = paginate(templates.preload(:author, folder: :parent_folder))

      schema_documents, dynamic_documents, preview_image_attachments = preload_relations(templates)

      expires_at = Accounts.link_expires_at(current_account)

      render json: {
        data: templates.map do |t|
          Templates::SerializeForApi.call(t,
                                          schema_documents: schema_documents.select { |e| e.record_id == t.id },
                                          dynamic_documents:,
                                          preview_image_attachments:,
                                          expires_at:)
        end,
        pagination: {
          count: templates.size,
          next: templates.last&.id,
          prev: templates.first&.id
        }
      }
    end

    def show
      render json: Templates::SerializeForApi.call(@template)
    end

    def update
      if (folder_name = params[:folder_name] || params.dig(:template, :folder_name))
        @template.folder = TemplateFolders.find_or_create_by_name(current_user, folder_name)
      end

      Array.wrap(params[:roles].presence || params.dig(:template, :roles).presence).each_with_index do |role, index|
        if (item = @template.submitters[index])
          item['name'] = role
        else
          @template.submitters << { 'name' => role, 'uuid' => SecureRandom.uuid }
        end
      end

      archived = params.key?(:archived) ? params[:archived] : params.dig(:template, :archived)

      if archived.in?([true, false]) && current_ability.can?(:destroy, @template)
        @template.archived_at = archived == true ? Time.current : nil
      end

      @template.update!(template_params)

      SearchEntries.enqueue_reindex(@template) if @template.saved_change_to_name?

      WebhookUrls.enqueue_events(@template, 'template.updated')

      if @template.saved_change_to_archived_at? && @template.archived_at?
        WebhookUrls.enqueue_events(@template, 'template.archived')
      end

      render json: @template.as_json(only: %i[id updated_at])
    end

    def destroy
      if params[:permanently].in?(['true', true])
        @template.destroy!
      else
        @template.update!(archived_at: Time.current)

        WebhookUrls.enqueue_events(@template, 'template.archived')
      end

      render json: @template.as_json(only: %i[id archived_at])
    end

    def pdf
      create_from_documents(:pdf)
    end

    def docx
      create_from_documents(:docx)
    end

    private

    def build_template
      @template = current_account.templates.new(
        author: current_user,
        source: 'api',
        name: params[:name].presence || SecureRandom.uuid,
        external_id: params[:external_id],
        shared_link: params[:shared_link] != false,
        fields: [],
        schema: []
      )

      if params[:folder_name].present?
        @template.folder = TemplateFolders.find_or_create_by_name(current_user, params[:folder_name])
      end

      authorize!(:create, @template)

      Templates.maybe_assign_access(@template)

      @template.save!
    end

    def create_from_documents(kind)
      documents = Array.wrap(params[:documents])

      raise CreationError, 'documents is required' if documents.empty?

      entries = []
      schema = []

      documents.each do |document_params|
        document_params = normalize_hash(document_params)

        bytes = decode_file(document_params[:file])
        pdf_bytes = kind == :docx ? convert_docx(bytes) : bytes

        result = Templates::FieldTags.call(
          pdf_bytes,
          remove_tags: !false_value?(params[:remove_tags]),
          unit_scale: 1.0
        )

        document = create_document!(result[:pdf], document_params[:name].presence || 'Document')

        entries.concat(attach_attachment_uuid(result[:entries], document.uuid))
        entries.concat(provided_field_entries(document_params[:fields], document.uuid))
        schema << schema_item(document, document_params[:name])
      end

      finalize_template!(entries, schema)
    end

    def finalize_template!(entries, schema)
      fields, submitters = Templates::FieldTags.build(entries, submitters: [])

      @template.update!(fields:, submitters:, schema:)

      WebhookUrls.enqueue_events(@template, 'template.created')
      SearchEntries.enqueue_reindex(@template)

      render json: Templates::SerializeForApi.call(@template.reload)
    end

    def create_document!(pdf_bytes, name)
      filename = "#{(name.presence || 'document').to_s.parameterize.presence || 'document'}.pdf"

      file = ActionDispatch::Http::UploadedFile.new(
        tempfile: StringIO.new(pdf_bytes),
        filename:,
        type: 'application/pdf'
      )

      documents, = Templates::CreateAttachments.call(@template, { files: [file] }, extract_fields: false)

      documents.first || raise(CreationError, 'Unable to attach document')
    end

    def attach_attachment_uuid(entries, attachment_uuid)
      entries.each { |entry| entry.area['attachment_uuid'] = attachment_uuid }

      entries
    end

    def schema_item(document, name)
      {
        'attachment_uuid' => document.uuid,
        'name' => name.presence || FilenameUtils.basename(document.blob[:filename])
      }
    end

    def decode_file(value)
      file = value.to_s.strip

      raise CreationError, 'file is required' if file.blank?

      if file.match?(%r{\Ahttps?://}i)
        DownloadUtils.call(file, validate: true).body
      else
        Base64.decode64(file.sub(/\Adata:[^,]*,/, '').tr('-_', '+/'))
      end
    rescue DownloadUtils::UnableToDownload => e
      raise CreationError, e.message
    end

    def convert_docx(bytes)
      require 'wordcraft'

      WordCraft.open_buffer(StringIO.new(bytes), &:to_pdf)
    rescue StandardError => e
      raise CreationError, "Invalid DOCX file: #{e.message}"
    end

    def provided_field_entries(fields, attachment_uuid)
      Array.wrap(fields).flat_map do |field|
        field = normalize_hash(field)
        options = Array.wrap(field[:options]).map { |option| option.is_a?(Hash) ? option[:value] : option }

        attributes = {
          'name' => field[:name].to_s,
          'type' => field[:type].presence || 'text',
          'role' => field[:role].presence,
          'required' => field[:required].to_s,
          'readonly' => field[:readonly].to_s,
          'title' => field[:title],
          'description' => field[:description],
          'default' => field[:default] || field[:default_value],
          'options' => options.join(','),
          'format' => field[:format],
          'pattern' => field[:pattern],
          'min' => field[:min],
          'max' => field[:max]
        }.compact

        Array.wrap(field[:areas]).map do |area|
          area = normalize_hash(area)

          area_attributes = attributes.dup
          area_attributes['option'] = area[:option] if area[:option].present?

          Templates::FieldTags::Entry.new(
            attributes: area_attributes,
            area: {
              'x' => area[:x].to_f,
              'y' => area[:y].to_f,
              'w' => area[:w].to_f,
              'h' => area[:h].to_f,
              'page' => [area[:page].to_i - 1, 0].max,
              'attachment_uuid' => attachment_uuid
            }
          )
        end
      end
    end

    def false_value?(value)
      value.in?([false, 'false', '0', 0])
    end

    def normalize_hash(value)
      hash = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value.to_h

      hash.with_indifferent_access
    end

    def preload_relations(templates)
      schema_documents =
        ActiveStorage::Attachment.where(record_id: templates.map(&:id),
                                        record_type: 'Template',
                                        name: :documents,
                                        uuid: templates.flat_map { |t| t.schema.pluck('attachment_uuid') })
                                 .preload(:blob)

      dynamic_document_uuids =
        templates.flat_map { |t| t.schema.select { |item| item['dynamic'] }.pluck('attachment_uuid') }

      dynamic_documents =
        if dynamic_document_uuids.present?
          DynamicDocument.where(template: templates.map(&:id))
                         .where(uuid: dynamic_document_uuids)
                         .preload(current_version: { document_attachment: :blob })
                         .select(:id, :uuid, :template_id, :sha1, :created_at, :updated_at)
        else
          DynamicDocument.none
        end

      preview_attachment_ids =
        schema_documents.map(&:id) + dynamic_documents.filter_map { |d| d.current_version&.document_attachment&.id }

      preview_image_attachments =
        ActiveStorage::Attachment.joins(:blob)
                                 .where(blob: { filename: ['0.png', '0.jpg'] })
                                 .where(record_id: preview_attachment_ids,
                                        record_type: 'ActiveStorage::Attachment',
                                        name: :preview_images)
                                 .preload(:blob)

      [schema_documents, dynamic_documents, preview_image_attachments]
    end

    def filter_templates(templates, params)
      templates =
        if params[:shared].in?(['true', true])
          Templates.search_shared(current_user, templates, params[:q])
        else
          Templates.search(current_user, templates, params[:q])
        end

      templates = params[:archived].in?(['true', true]) ? templates.archived : templates.active
      templates = templates.where(external_id: params[:application_key]) if params[:application_key].present?
      templates = templates.where(external_id: params[:external_id]) if params[:external_id].present?
      templates = templates.where(slug: params[:slug]) if params[:slug].present?

      if params[:folder].present?
        folders = TemplateFolders.filter_by_full_name(TemplateFolder.accessible_by(current_ability), params[:folder])

        templates = templates.where(folder_id: folders.pluck(:id))
      end

      templates
    end

    def template_params
      permitted_params = [
        :name,
        :external_id,
        :shared_link,
        {
          submitters: [%i[name uuid is_requester invite_by_uuid invite_via_field_uuid
                          optional_invite_by_uuid linked_to_uuid email order]],
          fields: [[:uuid, :submitter_uuid, :name, :type,
                    :required, :readonly, :default_value,
                    :title, :description, :prefillable,
                    { preferences: {},
                      default_value: [],
                      conditions: [%i[field_uuid value action operation]],
                      options: [%i[value uuid]],
                      validation: %i[message pattern min max step],
                      areas: [%i[uuid x y w h cell_w attachment_uuid option_uuid page]] }]]
        }
      ]

      if params.key?(:template)
        params.require(:template).permit(permitted_params)
      else
        params.permit(permitted_params)
      end
    end
  end
end
