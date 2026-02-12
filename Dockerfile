FROM ruby:3.3-slim

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY poll.rb ./

CMD ["ruby", "poll.rb"]
