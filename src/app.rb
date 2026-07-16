require "fileutils"
require "json"
require "opp"
require "sinatra/base"
require "sqlite3"
require "time"
require "uri"

class OppDirectory < Sinatra::Base
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
  end

  put "/:subject" do
    halt_json 415, "content type must be application/json" unless request.media_type == "application/json"

    body = request.body.read
    document = JSON.parse(body)
    halt_json 400, "registration must be an object" unless document.is_a?(Hash)
    halt_json 400, "subject does not match path" unless document["subject"] == params[:subject]

    OPP::Subject.verify!(document["subject"], public_key: document["public_key"])
    OPP::Signature.verify!(document, public_key: document["public_key"])

    self.class.database.execute(
      "INSERT INTO registrations(subject, sequence, document) VALUES (?, ?, ?)",
      [document["subject"], document["sequence"], body]
    )
    status 201
  rescue JSON::ParserError
    halt_json 400, "invalid JSON"
  rescue OPP::Error
    halt_json 422, "subject or signature verification failed"
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
