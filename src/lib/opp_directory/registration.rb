require "opp"
require "time"
require "uri"

module OppDirectory
  module Registration
    class Invalid < StandardError; end
    class VerificationFailed < StandardError; end

    REQUIRED_FIELDS = %w[type version subject public_key document_url sequence issued_at signature].freeze
    UTC_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

    module_function

    def parse(body)
      OPP::JSON.parse(body)
    rescue OPP::ParseError, OPP::DuplicateMemberError
      raise Invalid, "invalid JSON"
    end

    def create(document_url:, private_key:, public_key:, sequence:, issued_at: Time.now.utc)
      document = {
        "type" => "open-presence-directory-registration",
        "version" => "0.2",
        "subject" => OPP::Subject.derive(public_key),
        "public_key" => public_key,
        "document_url" => document_url,
        "sequence" => sequence,
        "issued_at" => issued_at.utc.iso8601
      }
      OPP::Signature.sign(document, private_key:).tap { |signed| verify!(signed) }
    rescue OPP::Error => error
      raise VerificationFailed, error.message
    end

    def verify!(document, expected_subject: nil)
      raise Invalid, "registration must be an object" unless document.is_a?(Hash)
      missing = REQUIRED_FIELDS.reject { |field| document.key?(field) }
      raise Invalid, "missing field: #{missing.first}" unless missing.empty?
      raise Invalid, "unsupported type" unless document["type"] == "open-presence-directory-registration"
      raise Invalid, "unsupported version" unless document["version"] == "0.2"
      raise Invalid, "subject must be a string" unless document["subject"].is_a?(String)
      raise Invalid, "public_key must be a string" unless document["public_key"].is_a?(String)
      if expected_subject && document["subject"] != expected_subject
        raise Invalid, "subject does not match path"
      end

      begin
        url = URI.parse(document["document_url"].to_s)
      rescue URI::InvalidURIError
        url = nil
      end
      unless url.is_a?(URI::HTTPS) && url.host && url.absolute?
        raise Invalid, "document_url must be an absolute HTTPS URL"
      end

      sequence = document["sequence"]
      unless sequence.is_a?(Integer) && sequence >= 0
        raise Invalid, "sequence must be a non-negative integer"
      end

      issued_at = document["issued_at"]
      unless issued_at.is_a?(String) && UTC_TIMESTAMP.match?(issued_at)
        raise Invalid, "issued_at must be an RFC 3339 UTC timestamp"
      end
      begin
        Time.iso8601(issued_at)
      rescue ArgumentError
        raise Invalid, "issued_at must be an RFC 3339 UTC timestamp"
      end

      signature = document["signature"]
      unless signature.is_a?(Hash) && signature.keys.sort == %w[algorithm value] &&
          signature["algorithm"] == "ed25519" && signature["value"].is_a?(String)
        raise Invalid, "signature must use ed25519"
      end

      begin
        OPP::Subject.verify!(document["subject"], public_key: document["public_key"])
        OPP::Signature.verify!(document, public_key: document["public_key"])
      rescue OPP::Error
        raise VerificationFailed, "subject or signature verification failed"
      end

      document
    end
  end
end
