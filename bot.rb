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
def get_recent_reports(report_type = nil)
  db = SQLite3::Database.new(DB_PATH)
  db.results_as_hash = true
  
  if report_type
    reports = db.execute(
      "SELECT * FROM reports WHERE report_type = ? AND created_at >= datetime('now', '-1 day') ORDER BY created_at DESC",
      [report_type]
    )
  else
    reports = db.execute(
      "SELECT * FROM reports WHERE created_at >= datetime('now', '-1 day') ORDER BY created_at DESC"
    )
  end
  
  db.close
  reports
end

# Форматирование уведомления
def format_notification(reports, single_type = false)
  return "📋 Отчётов за последние сутки нет." if reports.empty?

  type_names = {
    'overheat' => '🔥 Перегрев',
    'deviation' => '⚠️ Погрешность',
    'breakdown' => '🔧 Поломки',
    'unclear' => '❓ Непонятно'
  }

  if single_type
    # Для одного типа отчётов
    type = reports.first['report_type']
    text = "*#{type_names[type]}* за последние сутки:\n\n"
    reports.each do |item|
      time = item['created_at'].split(' ')[1] # только время
      date = item['created_at'].split(' ')[0] # дата
      text += "• #{date} #{time}\n  #{item['content']}\n\n"
    end
  else
    # Для всех типов (группируем)
    text = "📋 *Отчёт за последние сутки*\n\n"
    grouped = reports.group_by { |r| r['report_type'] }
    
    grouped.each do |type, items|
      text += "*#{type_names[type]}*\n"
      items.each do |item|
        time = item['created_at'].split(' ')[1] # только время
        text += "• #{time} — #{item['content']}\n"
      end
      text += "\n"
    end
  end
  
  text
end

# Главное меню
def main_menu
  Telegram::Bot::Types::ReplyKeyboardMarkup.new(
    keyboard: [
      [{ text: '📝 Ввести' }, { text: '📊 Посмотреть' }]
    ],
    resize_keyboard: true
  )
end

# Меню ввода данных
def input_menu
  Telegram::Bot::Types::ReplyKeyboardMarkup.new(
    keyboard: [
      [{ text: '🔥 Перегрев' }, { text: '⚠️ Погрешность' }],
      [{ text: '🔧 Поломки' }, { text: '❓ Непонятно' }],
      [{ text: '◀️ Назад' }]
    ],
    resize_keyboard: true
  )
end

# Меню просмотра данных
def view_menu
  Telegram::Bot::Types::ReplyKeyboardMarkup.new(
    keyboard: [
      [{ text: '🔥 Перегрев' }, { text: '⚠️ Погрешность' }],
      [{ text: '🔧 Поломки' }, { text: '❓ Непонятно' }],
      [{ text: '📋 Все' }],
      [{ text: '◀️ Назад' }]
    ],
    resize_keyboard: true
  )
end

# Состояние пользователя (ожидание ввода)
USER_STATES = {}

# Обработка выбора типа отчёта
def handle_report_type(bot, message, user_id, username, report_type, prompt_text)
  state = USER_STATES[user_id]
  return unless state
  
  if state[:mode] == 'input_menu'
    # Режим ввода
    USER_STATES[user_id] = { mode: 'waiting_input', report_type: report_type }
    bot.api.send_message(
      chat_id: message.chat.id,
      text: prompt_text,
      reply_markup: Telegram::Bot::Types::ReplyKeyboardRemove.new(remove_keyboard: true)
    )
  elsif state[:mode] == 'view_menu'
    # Режим просмотра
    reports = get_recent_reports(report_type)
    text = format_notification(reports, true)
    bot.api.send_message(
      chat_id: message.chat.id,
      text: text,
      parse_mode: 'Markdown',
      reply_markup: view_menu
    )
  end
end

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
          text: "Привет, #{username}! 👋\n\nВыберите действие:",
          reply_markup: main_menu
        )
        next
      end
      
      # Обработка главного меню
      case message.text
      when '📝 Ввести'
        USER_STATES[user_id] = { mode: 'input_menu' }
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Выберите тип отчёта:",
          reply_markup: input_menu
        )
        
      when '📊 Посмотреть'
        USER_STATES[user_id] = { mode: 'view_menu' }
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Что хотите посмотреть?",
          reply_markup: view_menu
        )
        
      when '◀️ Назад'
        USER_STATES.delete(user_id)
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Главное меню:",
          reply_markup: main_menu
        )
        
      when '🔥 Перегрев'
        handle_report_type(bot, message, user_id, username, 'overheat', 
                          "Введите данные по перегреву (адреса и градусы):\nНапример: ул. Ленина 5 - 85°C, пр. Мира 12 - 92°C")
        
      when '⚠️ Погрешность'
        handle_report_type(bot, message, user_id, username, 'deviation',
                          "Введите данные по погрешности (адреса и проценты):\nНапример: ул. Пушкина 7 - 15%, ул. Гагарина 3 - 8%")
        
      when '🔧 Поломки'
        handle_report_type(bot, message, user_id, username, 'breakdown',
                          "Введите данные по поломкам (адреса и причины):\nНапример: ул. Чехова 9 - протечка трубы")
        
      when '❓ Непонятно'
        handle_report_type(bot, message, user_id, username, 'unclear',
                          "Введите описание проблемы:")
        
      when '📋 Все'
        # Показать все отчёты
        if USER_STATES[user_id] && USER_STATES[user_id][:mode] == 'view_menu'
          reports = get_recent_reports
          text = format_notification(reports, false)
          bot.api.send_message(
            chat_id: message.chat.id,
            text: text,
            parse_mode: 'Markdown',
            reply_markup: view_menu
          )
        end
        
      else
        # Если пользователь в режиме ввода данных
        if USER_STATES[user_id] && USER_STATES[user_id][:mode] == 'waiting_input'
          report_type = USER_STATES[user_id][:report_type]
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

