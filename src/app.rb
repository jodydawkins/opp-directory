require "fileutils"
require "json"
require "opp"
require "sinatra/base"
require "sqlite3"
require "time"
require "uri"

class OppDirectory < Sinatra::Base
  class RegistrationError < StandardError
    attr_reader :status

    def initialize(status, message)
      @status = status
      super(message)
    end
  end

  REQUIRED_FIELDS = %w[type version subject public_key document_url sequence issued_at signature].freeze
  UTC_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

  configure do
    set :database_path, ENV.fetch("DATABASE_PATH", "db/opp-directory.sqlite3")
    set :show_exceptions, false
  end

  def self.database
    @database ||= begin
      path = settings.database_path
      FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
      SQLite3::Database.new(path).tap do |database|
        database.execute <<~SQL
          CREATE TABLE IF NOT EXISTS registrations (
            subject TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL,
            document TEXT NOT NULL
          )
        SQL
      end
    end
  end

  helpers do
    def registration(subject)
      self.class.database.get_first_value(
        "SELECT document FROM registrations WHERE subject = ?", subject
      )
    end

    def halt_json(status, message)
      halt status, { "Content-Type" => "application/json" }, JSON.generate(error: message)
    end

    def reject!(status, message)
      raise RegistrationError.new(status, message)
    end

    def validate_registration!(document, path_subject)
      reject! 400, "registration must be an object" unless document.is_a?(Hash)
      missing = REQUIRED_FIELDS.reject { |field| document.key?(field) }
      reject! 400, "missing field: #{missing.first}" unless missing.empty?
      reject! 400, "unsupported type" unless document["type"] == "open-presence-directory-registration"
      reject! 400, "unsupported version" unless document["version"] == "0.2"
      reject! 400, "subject must be a string" unless document["subject"].is_a?(String)
      reject! 400, "public_key must be a string" unless document["public_key"].is_a?(String)
      reject! 400, "subject does not match path" unless document["subject"] == path_subject

      begin
        url = URI.parse(document["document_url"].to_s)
      rescue URI::InvalidURIError
        url = nil
      end
      unless url.is_a?(URI::HTTPS) && url.host && url.absolute?
        reject! 400, "document_url must be an absolute HTTPS URL"
      end

      sequence = document["sequence"]
      reject! 400, "sequence must be a non-negative integer" unless sequence.is_a?(Integer) && sequence >= 0

      issued_at = document["issued_at"]
      unless issued_at.is_a?(String) && UTC_TIMESTAMP.match?(issued_at)
        reject! 400, "issued_at must be an RFC 3339 UTC timestamp"
      end
      begin
        Time.iso8601(issued_at)
      rescue ArgumentError
        reject! 400, "issued_at must be an RFC 3339 UTC timestamp"
      end

      signature = document["signature"]
      unless signature.is_a?(Hash) && signature["algorithm"] == "ed25519" && signature["value"].is_a?(String)
        reject! 400, "signature must use ed25519"
      end

      begin
        OPP::Subject.verify!(document["subject"], public_key: document["public_key"])
        OPP::Signature.verify!(document, public_key: document["public_key"])
      rescue OPP::Error
        reject! 422, "subject or signature verification failed"
      end
    end
  end

  put "/:subject" do
    reject! 415, "content type must be application/json" unless request.media_type == "application/json"
    body = request.body.read
    document = JSON.parse(body)
    validate_registration!(document, params[:subject])

    created = nil
    self.class.database.transaction(:immediate) do |database|
      created = database.get_first_value(
        "SELECT 1 FROM registrations WHERE subject = ?", document["subject"]
      ).nil?
      database.execute <<~SQL, [document["subject"], document["sequence"], body]
        INSERT INTO registrations(subject, sequence, document) VALUES (?, ?, ?)
        ON CONFLICT(subject) DO UPDATE SET
          sequence = excluded.sequence,
          document = excluded.document
        WHERE excluded.sequence > registrations.sequence
      SQL
      reject! 409, "sequence must be greater than the current sequence" if database.changes.zero?
    end

    status(created ? 201 : 200)
  rescue JSON::ParserError
    halt_json 400, "invalid JSON"
  rescue RegistrationError => error
    halt_json error.status, error.message
  end

  get "/:subject" do
    document = registration(params[:subject]) or halt 404
    content_type :json
    document
  end

  head "/:subject" do
    halt 404 unless registration(params[:subject])
    200
  end
end
