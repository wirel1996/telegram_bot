#!/usr/bin/env ruby
# frozen_string_literal: true

require 'telegram/bot'
require 'sqlite3'
require 'rufus-scheduler'
require 'dotenv/load'
require 'fileutils'

# Конфигурация
BOT_TOKEN = ENV.fetch('BOT_TOKEN')
ALLOWED_USER_IDS = ENV.fetch('ALLOWED_USER_IDS').split(',').map(&:strip).map(&:to_i)
TIMEZONE = ENV.fetch('TIMEZONE', 'Europe/Moscow')

DB_PATH = ENV.fetch('DB_PATH', './data/reports.db')

# Инициализация БД
def init_db
  FileUtils.mkdir_p(File.dirname(DB_PATH))
  db = SQLite3::Database.new(DB_PATH)
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      username TEXT,
      report_type TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  SQL
  db.close
end

# Сохранение отчёта
def save_report(user_id, username, report_type, content)
  db = SQLite3::Database.new(DB_PATH)
  db.execute(
    'INSERT INTO reports (user_id, username, report_type, content) VALUES (?, ?, ?, ?)',
    [user_id, username, report_type, content]
  )
  db.close
end

# Получение отчётов за последние 24 часа
def get_recent_reports
  db = SQLite3::Database.new(DB_PATH)
  db.results_as_hash = true
  reports = db.execute(
    "SELECT * FROM reports WHERE created_at >= datetime('now', '-1 day') ORDER BY created_at DESC"
  )
  db.close
  reports
end

# Форматирование уведомления
def format_notification(reports)
  return "📋 Отчётов за последние сутки нет." if reports.empty?

  text = "📋 *Отчёт за последние сутки*\n\n"
  
  # Группируем по типам
  grouped = reports.group_by { |r| r['report_type'] }
  
  type_names = {
    'overheat' => '🔥 Перегрев',
    'deviation' => '⚠️ Погрешность',
    'breakdown' => '🔧 Поломки',
    'unclear' => '❓ Непонятно'
  }
  
  grouped.each do |type, items|
    text += "*#{type_names[type]}*\n"
    items.each do |item|
      time = item['created_at'].split(' ')[1] # только время
      text += "• #{time} — #{item['content']}\n"
    end
    text += "\n"
  end
  
  text
end

# Основное меню
def main_menu
  Telegram::Bot::Types::ReplyKeyboardMarkup.new(
    keyboard: [
      [{ text: '🔥 Перегрев' }, { text: '⚠️ Погрешность' }],
      [{ text: '🔧 Поломки' }, { text: '❓ Непонятно' }]
    ],
    resize_keyboard: true
  )
end

# Состояние пользователя (ожидание ввода)
USER_STATES = {}

# Главная функция
def start_bot
  init_db
  
  Telegram::Bot::Client.run(BOT_TOKEN) do |bot|
    # Планировщик уведомлений
    scheduler = Rufus::Scheduler.new
    
    # Каждый день в 9:00 (пн-пт)
    scheduler.cron "0 9 * * 1-5 #{TIMEZONE}" do
      reports = get_recent_reports
      message = format_notification(reports)
      
      ALLOWED_USER_IDS.each do |user_id|
        bot.api.send_message(
          chat_id: user_id,
          text: message,
          parse_mode: 'Markdown'
        )
      rescue => e
        puts "Ошибка отправки уведомления #{user_id}: #{e.message}"
      end
    end
    
    puts "Бот запущен! Разрешённые пользователи: #{ALLOWED_USER_IDS.join(', ')}"
    
    # Обработка сообщений
    bot.listen do |message|
      next unless message.is_a?(Telegram::Bot::Types::Message)
      
      user_id = message.from.id
      username = message.from.username || message.from.first_name
      
      # Проверка доступа
      unless ALLOWED_USER_IDS.include?(user_id)
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "⛔️ У вас нет доступа к боту.\nВаш ID: #{user_id}"
        )
        next
      end
      
      # Команда /start
      if message.text == '/start'
        USER_STATES.delete(user_id)
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Привет, #{username}! 👋\n\nВыберите тип отчёта:",
          reply_markup: main_menu
        )
        next
      end
      
      # Обработка выбора типа отчёта
      case message.text
      when '🔥 Перегрев'
        USER_STATES[user_id] = 'overheat'
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Введите данные по перегреву (адреса и градусы):\nНапример: ул. Ленина 5 - 85°C, пр. Мира 12 - 92°C",
          reply_markup: Telegram::Bot::Types::ReplyKeyboardRemove.new(remove_keyboard: true)
        )
      when '⚠️ Погрешность'
        USER_STATES[user_id] = 'deviation'
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Введите данные по погрешности (адреса и проценты):\nНапример: ул. Пушкина 7 - 15%, ул. Гагарина 3 - 8%",
          reply_markup: Telegram::Bot::Types::ReplyKeyboardRemove.new(remove_keyboard: true)
        )
      when '🔧 Поломки'
        USER_STATES[user_id] = 'breakdown'
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Введите данные по поломкам (адреса и причины):\nНапример: ул. Чехова 9 - протечка трубы",
          reply_markup: Telegram::Bot::Types::ReplyKeyboardRemove.new(remove_keyboard: true)
        )
      when '❓ Непонятно'
        USER_STATES[user_id] = 'unclear'
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Введите описание проблемы:",
          reply_markup: Telegram::Bot::Types::ReplyKeyboardRemove.new(remove_keyboard: true)
        )
      else
        # Если пользователь в режиме ввода данных
        if USER_STATES.key?(user_id)
          report_type = USER_STATES[user_id]
          save_report(user_id, username, report_type, message.text)
          
          USER_STATES.delete(user_id)
          
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "✅ Данные сохранены!",
            reply_markup: main_menu
          )
        else
          # Неизвестная команда
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Используйте кнопки меню или /start",
            reply_markup: main_menu
          )
        end
      end
    end
  end
end

# Запуск
begin
  start_bot
rescue Interrupt
  puts "\n👋 Бот остановлен"
end

