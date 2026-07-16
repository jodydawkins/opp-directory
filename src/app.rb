require "fileutils"
require "json"
require "sinatra/base"
require "sqlite3"

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
