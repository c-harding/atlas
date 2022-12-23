FROM ruby:3.1.3

RUN bundle config --global frozen 1

COPY Gemfile Gemfile.lock /usr/src/app/

WORKDIR /usr/src/app

RUN bundle install

COPY . /usr/src/app/

EXPOSE 5000

CMD ["./atlas.rb"]
