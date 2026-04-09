package store

import (
	"database/sql"
	"log"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type Store struct {
	mu sync.RWMutex
	db *sql.DB
}

func New(dbPath string) *Store {
	db, err := sql.Open("sqlite3", dbPath+"?_busy_timeout=5000&_journal_mode=WAL")
	if err != nil {
		log.Fatalf("Failed to open store database: %v", err)
	}

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS message_to_user (
			message_id INTEGER PRIMARY KEY,
			user_id INTEGER NOT NULL
		);
		CREATE TABLE IF NOT EXISTS banned_users (
			user_id INTEGER PRIMARY KEY,
			expires_at TEXT NOT NULL,
			reason TEXT NOT NULL DEFAULT ''
		);
	`)
	if err != nil {
		log.Fatalf("Failed to create store tables: %v", err)
	}

	s := &Store{db: db}
	s.cleanupExpiredBans()
	return s
}

func (s *Store) SetMessage(msgID int, userID int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec("INSERT OR REPLACE INTO message_to_user (message_id, user_id) VALUES (?, ?)", msgID, userID)
}

func (s *Store) GetMessageUser(msgID int) (int64, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var userID int64
	err := s.db.QueryRow("SELECT user_id FROM message_to_user WHERE message_id = ?", msgID).Scan(&userID)
	if err != nil {
		return 0, false
	}
	return userID, true
}

func (s *Store) BanUser(userID int64, expiresAt time.Time, reason string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec("INSERT OR REPLACE INTO banned_users (user_id, expires_at, reason) VALUES (?, ?, ?)",
		userID, expiresAt.Format(time.RFC3339), reason)
}

func (s *Store) CheckBan(userID int64) (bool, time.Time, string) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var expiresAtStr, reason string
	err := s.db.QueryRow("SELECT expires_at, reason FROM banned_users WHERE user_id = ?", userID).Scan(&expiresAtStr, &reason)
	if err != nil {
		return false, time.Time{}, ""
	}

	expiresAt, err := time.Parse(time.RFC3339, expiresAtStr)
	if err != nil {
		return false, time.Time{}, ""
	}

	if time.Now().After(expiresAt) {
		s.db.Exec("DELETE FROM banned_users WHERE user_id = ?", userID)
		return false, time.Time{}, ""
	}

	return true, expiresAt, reason
}

func (s *Store) UnbanUser(userID int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.db.Exec("DELETE FROM banned_users WHERE user_id = ?", userID)
}

func (s *Store) cleanupExpiredBans() {
	now := time.Now().Format(time.RFC3339)
	s.db.Exec("DELETE FROM banned_users WHERE expires_at < ?", now)
}

func (s *Store) Close() {
	s.db.Close()
}
