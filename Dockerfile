FROM ruby:3.3-alpine

# Установка зависимостей для сборки гемов
RUN apk add --no-cache \
    build-base \
    sqlite-dev \
    tzdata

WORKDIR /app

# Копируем Gemfile и устанавливаем зависимости
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

# Копируем остальные файлы
COPY . .

# Создаём директорию для БД
RUN mkdir -p /app/data

# Запускаем бота
CMD ["bundle", "exec", "ruby", "bot.rb"]

