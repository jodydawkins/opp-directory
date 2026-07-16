FROM ruby:3.4-alpine

RUN apk add --no-cache build-base git sqlite-dev
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle config set without test && bundle install
COPY app.rb config.ru ./

ENV DATABASE_PATH=/data/opp-directory.sqlite3
VOLUME /data
EXPOSE 9292

CMD ["bundle", "exec", "rackup", "--host", "0.0.0.0", "--port", "9292"]
