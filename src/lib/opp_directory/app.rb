require "fileutils"
require "json"
require "sinatra/base"
require "sqlite3"
require_relative "registration"

module OppDirectory
  class App < Sinatra::Base
    class RegistrationError < StandardError
      attr_reader :status

      def initialize(status, message)
        @status = status
        super(message)
      end
    end

    configure do
      set :database_path, ENV.fetch("DATABASE_PATH", "db/opp-directory.sqlite3")
      set :lock, true
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
              sequence TEXT NOT NULL,
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
    end

    put "/:subject" do
      reject! 415, "content type must be application/json" unless request.media_type == "application/json"
      body = request.body.read
      document = Registration.parse(body)
      Registration.verify!(document, expected_subject: params[:subject])

      created = nil
      self.class.database.transaction(:immediate) do |database|
        created = database.get_first_value(
          "SELECT 1 FROM registrations WHERE subject = ?", document["subject"]
        ).nil?
        database.execute <<~SQL, [document["subject"], document["sequence"].to_s, body]
          INSERT INTO registrations(subject, sequence, document) VALUES (?, ?, ?)
          ON CONFLICT(subject) DO UPDATE SET
            sequence = excluded.sequence,
            document = excluded.document
          WHERE length(excluded.sequence) > length(registrations.sequence)
             OR (length(excluded.sequence) = length(registrations.sequence)
                 AND excluded.sequence > registrations.sequence)
        SQL
        reject! 409, "sequence must be greater than the current sequence" if database.changes.zero?
      end

      status(created ? 201 : 200)
    rescue Registration::Invalid => error
      halt_json 400, error.message
    rescue Registration::VerificationFailed => error
      halt_json 422, error.message
    rescue RegistrationError => error
      halt_json error.status, error.message
    end

    get "/health" do
      content_type :json
      { status: "ok" }.to_json
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
end
