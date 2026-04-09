package settings

import (
	"database/sql"
	"fmt"
	"log"
	"sync"

	_ "github.com/mattn/go-sqlite3"
)

type BotSettings struct {
	mu  sync.RWMutex
	db  *sql.DB
}

type MessageKey struct {
	Key     string
	Label   string
	Default string
}

var AvailableMessages = []MessageKey{
	{Key: "start_msg", Label: "Начальное сообщение", Default: "Привет! Это бот для отправки предложений. Напишите ваше сообщение, и оно будет доставлено администратору."},
	{Key: "take_msg", Label: "Сообщение запроса ввода", Default: "Пожалуйста, отправьте текстовое сообщение или медиафайл."},
	{Key: "gift_msg", Label: "Сообщение об успешной отправке текста", Default: "Ваше сообщение успешно отправлено администратору!"},
	{Key: "fgift_msg", Label: "Сообщение об успешной отправке файла", Default: "Ваш файл успешно отправлен администратору!"},
	{Key: "otvet_msg", Label: "Префикс ответа администратора", Default: "Ответ от администратора:"},
	{Key: "areply_msg", Label: "Сообщение админу об отправке ответа", Default: "Ваш ответ успешно отправлен пользователю!"},
	{Key: "aeror_msg", Label: "Сообщение об ошибке получателя", Default: "Не удалось определить получателя. Возможно, сообщение устарело."},
	{Key: "ar_msg", Label: "Подсказка админу про reply", Default: "Пожалуйста, ответьте на сообщение пользователя, чтобы отправить ему ответ."},
	{Key: "ban_usage_msg", Label: "Инструкция &#47;ban", Default: "Использование: /ban <user_id> <часы> [причина]\nИли ответьте на сообщение пользователя: /ban <часы> [причина]"},
	{Key: "ban_success_msg", Label: "Сообщение о блокировке (без причины)", Default: "Пользователь {user_id} заблокирован на {hours} ч."},
	{Key: "ban_success_reason_msg", Label: "Сообщение о блокировке (с причиной)", Default: "Пользователь {user_id} заблокирован на {hours} ч. Причина: {reason}"},
	{Key: "ban_no_reason_msg", Label: "Текст если причина не указана", Default: "Причина не указана."},
	{Key: "banned_msg", Label: "Сообщение заблокированному пользователю", Default: "Вы заблокированы.\nОсталось времени: {time}\nПричина: {reason}"},
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
