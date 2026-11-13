# frozen_string_literal: true

namespace :docuseal do
  desc 'Regenerate the self-hosted signing certificate using each account name'
  task regenerate_certificates: :environment do
    country = ENV.fetch('CERT_COUNTRY', 'AT')

    Account.find_each do |account|
      config = EncryptedConfig.find_or_initialize_by(account:, key: EncryptedConfig::ESIGN_CERTS_KEY)

      next if config.value.blank?

      certificate = GenerateCertificate.call(account.name, country:).transform_values(&:to_pem).transform_keys(&:to_s)

      config.value = config.value.to_h.transform_keys(&:to_s).merge(certificate)
      config.save!

      pkcs = GenerateCertificate.load_pkcs(config.reload.value)

      puts "Updated #{account.name}: signer=#{pkcs.certificate.subject} issuer=#{pkcs.ca_certs.first.subject}"
    end
  end
end
