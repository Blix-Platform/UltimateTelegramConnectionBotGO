package settings

import (
	"database/sql"
	"fmt"
	"log"
	"sync"

	_ "github.com/mattn/go-sqlite3"
)

type BotSettings struct {
	mu sync.RWMutex
	db *sql.DB
}

type MessageKey struct {
	Key      string
	Label    string
	Default  string
	Category string
}

type SettingsCategory struct {
	Name     string
	Icon     string
	Messages []MessageKey
}

var AvailableMessages = []MessageKey{
	// Пользовательские сообщения
	{Key: "start_msg", Label: "Приветствие", Default: "Привет! Это бот для отправки предложений. Напишите ваше сообщение, и оно будет доставлено администратору.", Category: "user"},
	{Key: "take_msg", Label: "Запрос ввода", Default: "Пожалуйста, отправьте текстовое сообщение или медиафайл.", Category: "user"},
	{Key: "gift_msg", Label: "Успешная отправка (текст)", Default: "Ваше сообщение успешно отправлено администратору!", Category: "user"},
	{Key: "fgift_msg", Label: "Успешная отправка (файл)", Default: "Ваш файл успешно отправлен администратору!", Category: "user"},

	// Админские сообщения
	{Key: "otvet_msg", Label: "Префикс ответа админа", Default: "Ответ от администратора:", Category: "admin"},
	{Key: "areply_msg", Label: "Админу об отправке ответа", Default: "Ваш ответ успешно отправлен пользователю!", Category: "admin"},
	{Key: "aeror_msg", Label: "Ошибка получателя", Default: "Не удалось определить получателя. Возможно, сообщение устарело.", Category: "admin"},
	{Key: "ar_msg", Label: "Подсказка про reply", Default: "Пожалуйста, ответьте на сообщение пользователя, чтобы отправить ему ответ.", Category: "admin"},

	// Блокировки
	{Key: "ban_usage_msg", Label: "Инструкция ban", Default: "Использование: /ban <user_id> <часы> [причина]\nИли ответьте на сообщение пользователя: /ban <часы> [причина]", Category: "ban"},
	{Key: "ban_success_msg", Label: "Бан (без причины)", Default: "Пользователь {user_id} заблокирован на {hours} ч.", Category: "ban"},
	{Key: "ban_success_reason_msg", Label: "Бан (с причиной)", Default: "Пользователь {user_id} заблокирован на {hours} ч. Причина: {reason}", Category: "ban"},
	{Key: "ban_no_reason_msg", Label: "Если причина не указана", Default: "Причина не указана.", Category: "ban"},
	{Key: "banned_msg", Label: "Сообщение заблокированному", Default: "Вы заблокированы.\nОсталось времени: {time}\nПричина: {reason}", Category: "ban"},
	{Key: "unban_success_msg", Label: "Успешный unban", Default: "✅ Пользователь {user_id} разблокирован", Category: "ban"},
	{Key: "unban_usage_msg", Label: "Инструкция unban", Default: "Использование: /unban <user_id>\nИли ответьте на сообщение пользователя: /unban", Category: "ban"},
}

var Categories = []SettingsCategory{
	{Name: "Админские сообщения", Icon: "🛡️", Messages: filterByCategory("admin")},
	{Name: "Пользовательские сообщения", Icon: "👤", Messages: filterByCategory("user")},
	{Name: "Блокировки", Icon: "🚫", Messages: filterByCategory("ban")},
}

func filterByCategory(cat string) []MessageKey {
	var result []MessageKey
	for _, mk := range AvailableMessages {
		if mk.Category == cat {
			result = append(result, mk)
		}
	}
	return result
}

func LoadSettings(dbPath string) *BotSettings {
	db, err := sql.Open("sqlite3", dbPath+"?_busy_timeout=5000&_journal_mode=WAL")
	if err != nil {
		log.Fatalf("Failed to open settings database: %v", err)
	}

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS messages (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL
		);
	`)
	if err != nil {
		log.Fatalf("Failed to create settings table: %v", err)
	}

	s := &BotSettings{db: db}
	s.initDefaults()
	return s
}

func (s *BotSettings) initDefaults() {
	for _, mk := range AvailableMessages {
		var exists int
		err := s.db.QueryRow("SELECT COUNT(*) FROM messages WHERE key = ?", mk.Key).Scan(&exists)
		if err != nil {
			log.Printf("Error checking key %s: %v", mk.Key, err)
			continue
		}
		if exists == 0 {
			_, err = s.db.Exec("INSERT INTO messages (key, value) VALUES (?, ?)", mk.Key, mk.Default)
			if err != nil {
				log.Printf("Error inserting default %s: %v", mk.Key, err)
			}
		}
	}
}

func (s *BotSettings) Get(key string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var value string
	err := s.db.QueryRow("SELECT value FROM messages WHERE key = ?", key).Scan(&value)
	if err != nil {
		for _, mk := range AvailableMessages {
			if mk.Key == key {
				return mk.Default
			}
		}
		return ""
	}
	return value
}

func (s *BotSettings) Set(key, value string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	_, err := s.db.Exec("INSERT OR REPLACE INTO messages (key, value) VALUES (?, ?)", key, value)
	return err
}

func (s *BotSettings) GetAll() map[string]string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rows, err := s.db.Query("SELECT key, value FROM messages")
	if err != nil {
		return nil
	}
	defer rows.Close()

	result := make(map[string]string)
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			continue
		}
		result[k] = v
	}
	return result
}

func (s *BotSettings) Close() {
	s.db.Close()
}

func (s *BotSettings) ResetToDefault(key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	for _, mk := range AvailableMessages {
		if mk.Key == key {
			_, err := s.db.Exec("UPDATE messages SET value = ? WHERE key = ?", mk.Default, key)
			return err
		}
	}
	return fmt.Errorf("unknown key: %s", key)
}

func (s *BotSettings) InitDefaults() int {
	count := 0
	for _, mk := range AvailableMessages {
		var exists int
		err := s.db.QueryRow("SELECT COUNT(*) FROM messages WHERE key = ?", mk.Key).Scan(&exists)
		if err != nil {
			continue
		}
		if exists == 0 {
			_, err = s.db.Exec("INSERT INTO messages (key, value) VALUES (?, ?)", mk.Key, mk.Default)
			if err == nil {
				count++
			}
		}
	}
	return count
}
