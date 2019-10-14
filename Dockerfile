FROM ruby:2.4-alpine

WORKDIR /app
USER daemon

RUN gem install aws-sdk-ecs
COPY ./action.rb .

ENTRYPOINT [ "ruby", "/app/action.rb" ]