ENV["RACK_ENV"] = "test"
ENV["DATABASE_PATH"] = ":memory:"

require "json"
require "minitest/autorun"
require "rack/test"
require_relative "../app"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app = OppDirectory

  def setup
    OppDirectory.database.execute("DELETE FROM registrations")
  end

  def path(subject)
    "/#{Rack::Utils.escape_path(subject)}"
  end

  def test_unknown_subject_is_not_found
    get path("key:sha256:missing")
    assert_equal 404, last_response.status

    head path("key:sha256:missing")
    assert_equal 404, last_response.status
    assert_empty last_response.body
  end

  def test_get_and_head_return_a_stored_registration
    body = %({ "subject": "key:sha256:known" }\n)
    OppDirectory.database.execute(
      "INSERT INTO registrations(subject, sequence, document) VALUES (?, ?, ?)",
      ["key:sha256:known", 1, body]
    )

    get path("key:sha256:known")
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.media_type
    assert_equal body, last_response.body

    head path("key:sha256:known")
    assert_equal 200, last_response.status
    assert_empty last_response.body
  end
end
