package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"

	"UltimateTelegramConnectionBotGO/internal/handler"
	"UltimateTelegramConnectionBotGO/internal/settings"
	"UltimateTelegramConnectionBotGO/internal/store"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
)

func main() {
	botToken := os.Getenv("BOT_TOKEN")
	adminIDStr := os.Getenv("ADMIN_ID")

	if botToken == "" || adminIDStr == "" {
		log.Fatal("BOT_TOKEN and ADMIN_ID environment variables must be set")
	}

	adminID, err := strconv.ParseInt(adminIDStr, 10, 64)
	if err != nil {
		log.Fatal(fmt.Sprintf("Invalid ADMIN_ID: %s", adminIDStr))
	}

	bot, err := tgbotapi.NewBotAPI(botToken)
	if err != nil {
		log.Fatal(err)
	}

	bot.Debug = false
	log.Printf("Авторизация: %s", bot.Self.UserName)

	execPath, err := os.Executable()
	if err != nil {
		execPath = "."
	}
	configDir := filepath.Dir(execPath)

	dbPath := filepath.Join(configDir, "bot.db")
	st := settings.LoadSettings(dbPath)
	str := store.New(dbPath)
	h := handler.New(bot, str, st, adminID)

	defer st.Close()
	defer str.Close()

	u := tgbotapi.NewUpdate(0)
	u.Timeout = 60

	updates := bot.GetUpdatesChan(u)

	for update := range updates {
		h.HandleUpdate(update)
	}
}
