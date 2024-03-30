FROM ruby:3.1 AS base
ENV RUBY_YJIT_ENABLE=1
WORKDIR /app

FROM base AS prod
COPY Gemfile .
COPY Gemfile.lock .
RUN bundle install
COPY . .
EXPOSE 3000
CMD ["ruby", "async_server.rb"]