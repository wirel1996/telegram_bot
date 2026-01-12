#!/usr/bin/env ruby
# frozen_string_literal: true

require 'telegram/bot'
require 'sqlite3'
require 'rufus-scheduler'
require 'dotenv/load'
require 'fileutils'
require 'spreadsheet'
require 'date'

# Подавляем предупреждения от Spreadsheet о формулах
Spreadsheet.client_encoding = 'UTF-8'

# Конфигурация
BOT_TOKEN = ENV.fetch('BOT_TOKEN')
ALLOWED_USER_IDS = ENV.fetch('ALLOWED_USER_IDS').split(',').map(&:strip).map(&:to_i)
TIMEZONE = ENV.fetch('TIMEZONE', 'Europe/Moscow')

DB_PATH = ENV.fetch('DB_PATH', './data/reports.db')
EXCEL_FILE_PATH = ENV.fetch('EXCEL_FILE_PATH', './Сведения о приборах.xls')

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

# Получение всех отчётов
def get_all_reports(report_type = nil)
  db = SQLite3::Database.new(DB_PATH)
  db.results_as_hash = true
  
  if report_type
    reports = db.execute(
      "SELECT * FROM reports WHERE report_type = ? ORDER BY created_at DESC",
      [report_type]
    )
  else
    reports = db.execute(
      "SELECT * FROM reports ORDER BY created_at DESC"
    )
  end
  
  db.close
  reports
end

# Получение отчёта по ID
def get_report_by_id(report_id)
  db = SQLite3::Database.new(DB_PATH)
  db.results_as_hash = true
  report = db.execute("SELECT * FROM reports WHERE id = ?", [report_id]).first
  db.close
  report
end

# Удаление отчёта
def delete_report(report_id)
  db = SQLite3::Database.new(DB_PATH)
  db.execute("DELETE FROM reports WHERE id = ?", [report_id])
  db.close
end

# Форматирование уведомления
def format_notification(reports, single_type = false)
  return "📋 Активных задач нет." if reports.empty?

  type_names = {
    'overheat' => '🔥 Перегрев',
    'deviation' => '⚠️ Погрешность',
    'breakdown' => '🔧 Поломки',
    'unclear' => '❓ Непонятно'
  }

  if single_type
    # Для одного типа отчётов
    type = reports.first['report_type']
    text = "*#{type_names[type]}:*\n\n"
    reports.each do |item|
      time = item['created_at'].split(' ')[1] # только время
      date = item['created_at'].split(' ')[0] # дата
      text += "• #{date} #{time}\n  #{item['content']}\n\n"
    end
  else
    # Для всех типов (группируем)
    text = "📋 *Список активных задач:*\n\n"
    grouped = reports.group_by { |r| r['report_type'] }
    
    grouped.each do |type, items|
      text += "*#{type_names[type]}*\n"
      items.each do |item|
        date = item['created_at'].split(' ')[0]
        time = item['created_at'].split(' ')[1]
        text += "• #{date} #{time} — #{item['content']}\n"
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
      [{ text: '📝 Ввести' }, { text: '📊 Посмотреть' }],
      [{ text: '🗑️ Удалить' }, { text: '📄 Поверка приборов' }]
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

# Меню удаления данных
def delete_menu
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

# Удаление сообщения пользователя (кнопки)
def delete_user_message(bot, message)
  bot.api.delete_message(chat_id: message.chat.id, message_id: message.message_id)
rescue => e
  # Игнорируем ошибки (например, если сообщение слишком старое)
  puts "Не удалось удалить сообщение: #{e.message}"
end

# Чтение Excel файла с приборами
def read_devices_from_excel
  unless File.exist?(EXCEL_FILE_PATH)
    return "❌ Файл не найден: #{EXCEL_FILE_PATH}"
  end
  
  begin
    book = Spreadsheet.open(EXCEL_FILE_PATH)
    sheet = book.worksheet(0) # первый лист
    
    devices = []
    
    # Текущая дата и дата через 3 месяца
    today = Date.today
    three_months_later = today >> 3 # >> 3 означает +3 месяца
    
    # Пропускаем заголовок (строка 0), начинаем со строки 1
    sheet.each(1) do |row|
      next if row.nil? || row.empty?
      
      # Столбец A (индекс 0), столбец B (индекс 1), столбец AP (индекс 41, т.к. AP = 42-я буква)
      col_a = row[0]&.to_s&.strip
      col_b = row[1]&.to_s&.strip
      col_ap = row[41] # AP - это 42-й столбец (индекс 41)
      
      # Пропускаем пустые строки
      next if col_a.nil? || col_a.empty?
      next if col_ap.nil?
      
      # Объединяем A и B через пробел (сначала фильтруем nil и пустые)
      device_name = [col_a, col_b].compact.reject(&:empty?).join(' ')
      
      # Получаем дату для фильтрации
      verification_date_obj = if col_ap.is_a?(Date)
                                col_ap
                              elsif col_ap.is_a?(Time) || col_ap.is_a?(DateTime)
                                col_ap.to_date
                              else
                                # Пропускаем если дата не в нужном формате
                                next
                              end
      
      # Фильтруем: только даты от сегодня до +3 месяца
      next if verification_date_obj < today
      next if verification_date_obj > three_months_later
      
      # Форматируем дату для вывода
      verification_date_str = verification_date_obj.strftime('%d.%m.%Y')
      
      # Считаем дни до поверки
      days_left = (verification_date_obj - today).to_i
      
      devices << { 
        name: device_name, 
        date: verification_date_str,
        date_obj: verification_date_obj,
        days_left: days_left
      }
    end
    
    if devices.empty?
      return "✅ Нет приборов с поверкой в ближайшие 3 месяца"
    end
    
    # Сортируем по дате (ближайшие сверху)
    devices.sort_by! { |d| d[:date_obj] }
    
    # Форматируем вывод
    text = "📄 Поверка приборов\n\n"
    
    devices.each_with_index do |device, index|
      text += "#{index + 1}. #{device[:name]}\n"
      text += "   📅 #{device[:date]}\n\n"
    end
    
    text
  rescue => e
    "❌ Ошибка чтения файла: #{e.message}"
  end
end

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
    reports = get_all_reports(report_type)
    text = format_notification(reports, true)
    bot.api.send_message(
      chat_id: message.chat.id,
      text: text,
      parse_mode: 'Markdown',
      reply_markup: view_menu
    )
  elsif state[:mode] == 'delete_menu'
    # Режим удаления
    show_delete_list(bot, message, report_type)
  end
end

# Показать список для удаления с inline кнопками
def show_delete_list(bot, message, report_type)
  reports = get_all_reports(report_type)
  
  if reports.empty?
    bot.api.send_message(
      chat_id: message.chat.id,
      text: "Нет задач для удаления",
      reply_markup: delete_menu
    )
    return
  end
  
  type_names = {
    'overheat' => '🔥 Перегрев',
    'deviation' => '⚠️ Погрешность',
    'breakdown' => '🔧 Поломки',
    'unclear' => '❓ Непонятно'
  }
  
  text = "Выберите задачу для удаления:\n\n"
  keyboard = []
  
  reports.each do |item|
    date = item['created_at'].split(' ')[0]
    time = item['created_at'].split(' ')[1].split(':')[0..1].join(':') # только часы:минуты
    type_icon = type_names[item['report_type']]
    
    # Обрезаем контент если слишком длинный (для кнопки)
    content_preview = item['content'].length > 50 ? item['content'][0..50] + '...' : item['content']
    
    button_text = "#{date} #{time} — #{content_preview}"
    keyboard << [Telegram::Bot::Types::InlineKeyboardButton.new(
      text: button_text,
      callback_data: "delete_#{item['id']}"
    )]
  end
  
  markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
  
  bot.api.send_message(
    chat_id: message.chat.id,
    text: text,
    reply_markup: markup
  )
end

# Главная функция
def start_bot
  init_db
  
  Telegram::Bot::Client.run(BOT_TOKEN) do |bot|
    # Планировщик уведомлений
    scheduler = Rufus::Scheduler.new
    
    # Каждый день в 9:00 (пн-пт)
    scheduler.cron "0 9 * * 1-5 #{TIMEZONE}" do
      reports = get_all_reports
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
    
    # Обработка callback (нажатия на inline кнопки)
    bot.listen do |update|
      # Обработка callback queries (удаление)
      if update.is_a?(Telegram::Bot::Types::CallbackQuery)
        callback = update
        user_id = callback.from.id
        
        # Проверка доступа
        unless ALLOWED_USER_IDS.include?(user_id)
          bot.api.answer_callback_query(callback_query_id: callback.id, text: "Нет доступа")
          next
        end
        
        if callback.data.start_with?('delete_')
          report_id = callback.data.split('_')[1].to_i
          report = get_report_by_id(report_id)
          
          if report
            delete_report(report_id)
            bot.api.answer_callback_query(
              callback_query_id: callback.id,
              text: "✅ Задача удалена"
            )
            
            # Обновляем сообщение
            bot.api.edit_message_text(
              chat_id: callback.message.chat.id,
              message_id: callback.message.message_id,
              text: "✅ Задача удалена:\n\n#{report['content']}"
            )
          else
            bot.api.answer_callback_query(
              callback_query_id: callback.id,
              text: "❌ Задача не найдена"
            )
          end
        end
        
        next
      end
      
      # Обработка обычных сообщений
      message = update
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
        delete_user_message(bot, message)
        USER_STATES[user_id] = { mode: 'input_menu' }
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Выберите что вывести:",
          reply_markup: input_menu
        )
        
      when '📊 Посмотреть'
        delete_user_message(bot, message)
        USER_STATES[user_id] = { mode: 'view_menu' }
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Что хотите посмотреть?",
          reply_markup: view_menu
        )
        
      when '🗑️ Удалить'
        delete_user_message(bot, message)
        USER_STATES[user_id] = { mode: 'delete_menu' }
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Выберите тип задач для удаления:",
          reply_markup: delete_menu
        )
        
      when '◀️ Назад'
        delete_user_message(bot, message)
        USER_STATES.delete(user_id)
        bot.api.send_message(
          chat_id: message.chat.id,
          text: "Главное меню:",
          reply_markup: main_menu
        )
        
      when '📄 Поверка приборов'
        delete_user_message(bot, message)
        text = read_devices_from_excel
        bot.api.send_message(
          chat_id: message.chat.id,
          text: text,
          reply_markup: main_menu
        )
        
      when '🔥 Перегрев'
        delete_user_message(bot, message)
        handle_report_type(bot, message, user_id, username, 'overheat', 
                          "Введите данные по перегреву.\n\n📝 Каждый адрес с новой строки:\nЛенина 5 - 85°C\nМира 12 - 92°C")
        
      when '⚠️ Погрешность'
        delete_user_message(bot, message)
        handle_report_type(bot, message, user_id, username, 'deviation',
                          "Введите данные по погрешности.\n\n📝 Каждый адрес с новой строки:\nПушкина 7 - 15%\nГагарина 3 - 8%")
        
      when '🔧 Поломки'
        delete_user_message(bot, message)
        handle_report_type(bot, message, user_id, username, 'breakdown',
                          "Введите данные по поломкам.\n\n📝 Каждый адрес с новой строки:\nЧехова 9 - протечка трубы\nТолстого 15 - сломан вентиль")
        
      when '❓ Непонятно'
        delete_user_message(bot, message)
        handle_report_type(bot, message, user_id, username, 'unclear',
                          "Введите описание проблемы.\n\n📝 Каждая проблема с новой строки.")
        
      when '📋 Все'
        delete_user_message(bot, message)
        state = USER_STATES[user_id]
        if state
          if state[:mode] == 'view_menu'
            # Показать все отчёты
            reports = get_all_reports
            text = format_notification(reports, false)
            bot.api.send_message(
              chat_id: message.chat.id,
              text: text,
              parse_mode: 'Markdown',
              reply_markup: view_menu
            )
          elsif state[:mode] == 'delete_menu'
            # Показать все для удаления
            show_delete_list(bot, message, nil)
          end
        end
        
      else
        # Если пользователь в режиме ввода данных
        if USER_STATES[user_id] && USER_STATES[user_id][:mode] == 'waiting_input'
          report_type = USER_STATES[user_id][:report_type]
          
          # Разбиваем на строки и сохраняем каждую как отдельную задачу
          lines = message.text.split("\n").map(&:strip).reject(&:empty?)
          
          if lines.empty?
            bot.api.send_message(
              chat_id: message.chat.id,
              text: "❌ Пустое сообщение. Попробуйте снова.",
              reply_markup: main_menu
            )
          else
            lines.each do |line|
              save_report(user_id, username, report_type, line)
            end
            
            count_text = lines.size == 1 ? "задача" : lines.size < 5 ? "задачи" : "задач"
            
            bot.api.send_message(
              chat_id: message.chat.id,
              text: "✅ Сохранено #{lines.size} #{count_text}!",
              reply_markup: main_menu
            )
          end
          
          USER_STATES.delete(user_id)
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

