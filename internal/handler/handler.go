package handler

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"UltimateTelegramConnectionBotGO/internal/settings"
	"UltimateTelegramConnectionBotGO/internal/store"
	"UltimateTelegramConnectionBotGO/internal/version"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
)

type Handler struct {
	bot      *tgbotapi.BotAPI
	store    *store.Store
	settings *settings.BotSettings
	adminID  int64

	mu            sync.Mutex
	editingAdmins map[int64]string
}

func New(bot *tgbotapi.BotAPI, s *store.Store, st *settings.BotSettings, adminID int64) *Handler {
	return &Handler{
		bot: bot, store: s, settings: st, adminID: adminID,
		editingAdmins: make(map[int64]string),
	}
}

func (h *Handler) HandleUpdate(update tgbotapi.Update) {
	if update.Message == nil {
		if update.CallbackQuery != nil {
			h.handleCallback(update.CallbackQuery)
		}
		return
	}

	msg := update.Message

	if msg.Chat.ID == h.adminID {
		h.mu.Lock()
		editingKey, isEditing := h.editingAdmins[msg.Chat.ID]
		h.mu.Unlock()

		if isEditing && !msg.IsCommand() {
			h.handleSettingsEdit(msg, editingKey)
			return
		}
	}

	if msg.IsCommand() {
		switch msg.Command() {
		case "start":
			h.handleStart(msg)
		case "ban":
			h.handleBan(msg)
		case "settings":
			h.handleSettings(msg)
		case "unban":
			h.handleUnban(msg)
		case "update":
			h.handleUpdate(msg)
		case "resetsettings":
			h.handleResetSettings(msg)
		case "version":
			h.handleVersion(msg)
		}
		return
	}

	if msg.Chat.ID == h.adminID {
		h.handleAdminMessage(msg)
	} else {
		h.handleUserMessage(msg)
	}
}

func (h *Handler) handleStart(message *tgbotapi.Message) {
	msg := tgbotapi.NewMessage(message.Chat.ID, h.settings.Get("start_msg"))
	h.bot.Send(msg)
}

func (h *Handler) handleUserMessage(message *tgbotapi.Message) {
	banned, expiresAt, reason := h.store.CheckBan(message.Chat.ID)
	if banned {
		h.sendBannedMessage(message.Chat.ID, expiresAt, reason)
		return
	}

	if !isSupportedContent(message) {
		msg := tgbotapi.NewMessage(message.Chat.ID, h.settings.Get("take_msg"))
		h.bot.Send(msg)
		return
	}

	forwardMsg := tgbotapi.NewForward(h.adminID, message.Chat.ID, message.MessageID)
	sentMsg, err := h.bot.Send(forwardMsg)
	if err != nil {
		msg := tgbotapi.NewMessage(message.Chat.ID, "Произошла ошибка при отправке сообщения. Попробуйте позже.")
		h.bot.Send(msg)
		log.Printf("Error forwarding: %s", err)
		return
	}

	h.store.SetMessage(sentMsg.MessageID, message.Chat.ID)

	replyText := h.settings.Get("gift_msg")
	if message.Text == "" {
		replyText = h.settings.Get("fgift_msg")
	}

	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, replyText))
}

func (h *Handler) handleAdminMessage(message *tgbotapi.Message) {
	if message.ReplyToMessage == nil {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, h.settings.Get("ar_msg")))
		return
	}

	originalID := message.ReplyToMessage.MessageID
	userID, exists := h.store.GetMessageUser(originalID)
	if !exists {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, h.settings.Get("aeror_msg")))
		return
	}

	caption := h.settings.Get("otvet_msg")
	if message.Caption != "" {
		caption = fmt.Sprintf("%s\n%s", h.settings.Get("otvet_msg"), message.Caption)
	}

	var err error
	switch {
	case message.Text != "":
		fullText := fmt.Sprintf("%s\n%s", h.settings.Get("otvet_msg"), message.Text)
		_, err = h.bot.Send(tgbotapi.NewMessage(userID, fullText))
	case len(message.Photo) > 0:
		photo := message.Photo[len(message.Photo)-1]
		m := tgbotapi.NewPhoto(userID, tgbotapi.FilePath(photo.FileID))
		m.Caption = caption
		_, err = h.bot.Send(m)
	case message.Video != nil:
		m := tgbotapi.NewVideo(userID, tgbotapi.FilePath(message.Video.FileID))
		m.Caption = caption
		_, err = h.bot.Send(m)
	case message.Document != nil:
		m := tgbotapi.NewDocument(userID, tgbotapi.FilePath(message.Document.FileID))
		m.Caption = caption
		_, err = h.bot.Send(m)
	case message.Audio != nil:
		m := tgbotapi.NewAudio(userID, tgbotapi.FilePath(message.Audio.FileID))
		m.Caption = caption
		_, err = h.bot.Send(m)
	case message.Voice != nil:
		_, err = h.bot.Send(tgbotapi.NewVoice(userID, tgbotapi.FilePath(message.Voice.FileID)))
	}

	if err != nil {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, "Произошла ошибка при отправке ответа."))
		log.Printf("Error sending reply: %s", err)
		return
	}

	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, h.settings.Get("areply_msg")))
}

func (h *Handler) handleBan(message *tgbotapi.Message) {
	if message.Chat.ID != h.adminID {
		return
	}

	args := strings.SplitN(message.Text, " ", 4)
	args = args[1:]

	var userID int64
	var hours float64
	var reason string
	var parseErr string

	if message.ReplyToMessage != nil {
		originalID := message.ReplyToMessage.MessageID
		uid, exists := h.store.GetMessageUser(originalID)
		if !exists {
			h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, h.settings.Get("aeror_msg")))
			return
		}
		userID = uid
		if len(args) < 1 {
			parseErr = h.settings.Get("ban_usage_msg")
		} else {
			hr, err := strconv.ParseFloat(args[0], 64)
			if err != nil {
				parseErr = h.settings.Get("ban_usage_msg")
			} else {
				hours = hr
			}
			if len(args) > 1 {
				reason = strings.Join(args[1:], " ")
			}
		}
	} else {
		if len(args) < 2 {
			parseErr = h.settings.Get("ban_usage_msg")
		} else {
			id, err := strconv.ParseInt(args[0], 10, 64)
			if err != nil {
				parseErr = h.settings.Get("ban_usage_msg")
			} else {
				userID = id
			}
			hr, err := strconv.ParseFloat(args[1], 64)
			if err != nil {
				parseErr = h.settings.Get("ban_usage_msg")
			} else {
				hours = hr
			}
			if len(args) > 2 {
				reason = strings.Join(args[2:], " ")
			}
		}
	}

	if parseErr != "" {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, parseErr))
		return
	}

	if userID == h.adminID {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, "❌ Нельзя заблокировать администратора"))
		return
	}

	if userID == h.bot.Self.ID {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, "❌ Нельзя заблокировать самого бота"))
		return
	}

	h.store.BanUser(userID, time.Now().Add(time.Duration(hours)*time.Hour), reason)

	var response string
	if reason != "" {
		response = h.settings.Get("ban_success_reason_msg")
		response = strings.ReplaceAll(response, "{user_id}", strconv.FormatInt(userID, 10))
		response = strings.ReplaceAll(response, "{hours}", strconv.FormatFloat(hours, 'f', -1, 64))
		response = strings.ReplaceAll(response, "{reason}", reason)
	} else {
		response = h.settings.Get("ban_success_msg")
		response = strings.ReplaceAll(response, "{user_id}", strconv.FormatInt(userID, 10))
		response = strings.ReplaceAll(response, "{hours}", strconv.FormatFloat(hours, 'f', -1, 64))
	}

	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, response))
}

func (h *Handler) handleUnban(message *tgbotapi.Message) {
	if message.Chat.ID != h.adminID {
		return
	}

	args := strings.Fields(message.Text)

	var userID int64
	var parseErr string

	if message.ReplyToMessage != nil {
		originalID := message.ReplyToMessage.MessageID
		uid, exists := h.store.GetMessageUser(originalID)
		if !exists {
			h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, h.settings.Get("aeror_msg")))
			return
		}
		userID = uid
	} else {
		if len(args) < 2 {
			parseErr = h.settings.Get("unban_usage_msg")
		} else {
			id, err := strconv.ParseInt(args[1], 10, 64)
			if err != nil {
				parseErr = h.settings.Get("unban_usage_msg")
			} else {
				userID = id
			}
		}
	}

	if parseErr != "" {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, parseErr))
		return
	}

	h.store.UnbanUser(userID)

	response := h.settings.Get("unban_success_msg")
	response = strings.ReplaceAll(response, "{user_id}", strconv.FormatInt(userID, 10))
	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, response))
}

func (h *Handler) handleUpdate(message *tgbotapi.Message) {
	if message.Chat.ID != h.adminID {
		return
	}

	execPath, _ := os.Executable()
	installDir := filepath.Dir(execPath)
	commitFile := filepath.Join(installDir, ".commit")

	currentCommit := ""
	if data, err := os.ReadFile(commitFile); err == nil {
		currentCommit = strings.TrimSpace(string(data))
	}

	currentVer := version.VersionString()
	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, fmt.Sprintf("⏳ Проверка обновлений...\nТекущая версия: v%s", currentVer)))

	commits, err := version.CheckUPCommits(currentCommit)
	if err != nil {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, fmt.Sprintf("❌ %s", err.Error())))
		return
	}

	if len(commits) == 0 {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, "✅ У вас последняя версия. Нет доступных обновлений [UP]."))
		return
	}

	var summary strings.Builder
	summary.WriteString(fmt.Sprintf("📦 Найдено обновлений [UP]: %d\n\n", len(commits)))
	for i, c := range commits {
		msg := c.Message
		if len(msg) > 80 {
			msg = msg[:80] + "..."
		}
		summary.WriteString(fmt.Sprintf("%d. %s\n   Файлов: %d\n", i+1, msg, len(c.Filenames)))
	}
	summary.WriteString("\n⬇️ Загрузка изменённых файлов...")

	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, summary.String()))

	totalUpdated := 0
	totalSkipped := 0
	totalErrors := 0

	for _, commit := range commits {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, fmt.Sprintf("🔄 Применяю: %s", commit.Message)))

		for _, fname := range commit.Filenames {
			if !isUpdateableFile(fname) {
				totalSkipped++
				continue
			}

			content, err := version.GetFileContent(fname, commit.SHA)
			if err != nil {
				h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, fmt.Sprintf("⚠️ Пропуск %s: %s", fname, err.Error())))
				totalErrors++
				continue
			}

			localPath := filepath.Join(installDir, fname)
			skip := false
			if existing, err := os.ReadFile(localPath); err == nil {
				if version.FileMD5(existing) == version.FileMD5(content) {
					skip = true
				}
			}

			if skip {
				totalSkipped++
				continue
			}

			os.MkdirAll(filepath.Dir(localPath), 0755)
			if err := os.WriteFile(localPath, content, 0644); err != nil {
				h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, fmt.Sprintf("❌ Ошибка записи %s: %s", fname, err.Error())))
				totalErrors++
				continue
			}

			totalUpdated++
		}
	}

	os.WriteFile(commitFile, []byte(commits[0].SHA), 0644)

	resultMsg := fmt.Sprintf("✅ Обновление применено!\n\n"+
		"📝 Обновлено файлов: %d\n"+
		"⏭️ Пропущено (без изменений): %d\n"+
		"❌ Ошибок: %d\n\n"+
		"Текущий коммит: %s", totalUpdated, totalSkipped, totalErrors, commits[0].SHA[:7])

	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, resultMsg))

	updateScript := filepath.Join(installDir, "update.sh")
	os.Chmod(updateScript, 0755)

	cmd := exec.Command("sudo", "bash", updateScript, "--post-update")
	cmd.Stdout = nil
	cmd.Stderr = nil
	err = cmd.Start()
	if err != nil {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, fmt.Sprintf("❌ Ошибка запуска скрипта: %s", err.Error())))
		return
	}
	cmd.Process.Release()

	go func() {
		time.Sleep(3 * time.Second)
		os.Exit(0)
	}()
}

func isUpdateableFile(fname string) bool {
	parts := strings.Split(fname, "/")
	if len(parts) < 2 {
		return false
	}
	switch parts[0] {
	case "cmd", "internal":
		return true
	}
	ext := filepath.Ext(fname)
	switch ext {
	case ".go", ".mod", ".sum", ".sh":
		return true
	}
	return false
}

func (h *Handler) handleSettings(message *tgbotapi.Message) {
	if message.Chat.ID != h.adminID {
		return
	}

	h.sendMainSettingsMenu(message.Chat.ID)
}

func (h *Handler) handleCallback(cb *tgbotapi.CallbackQuery) {
	switch {
	case cb.Data == "section_messages":
		h.sendCategoriesMenu(cb.Message.Chat.ID)
		h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})
	case cb.Data == "section_update":
		h.sendUpdateSection(cb)
	case cb.Data == "do_update":
		h.doUpdateFromSettings(cb)
	case strings.HasPrefix(cb.Data, "edit_"):
		h.handleEditButton(cb)
	case cb.Data == "back_to_main_settings":
		h.handleBackToMainSettings(cb)
	case cb.Data == "back_to_settings":
		h.handleBackToSettings(cb)
	case strings.HasPrefix(cb.Data, "cat_"):
		h.handleCategoryButton(cb)
	}
}

func (h *Handler) sendMainSettingsMenu(chatID int64) {
	keyboard := tgbotapi.NewInlineKeyboardMarkup(
		tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData("💬 Сообщения", "section_messages"),
		),
		tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData("🔄 Обновить систему", "section_update"),
		),
	)

	msg := tgbotapi.NewMessage(chatID, "⚙️ <b>Настройки</b>\n\nВыберите раздел:")
	msg.ParseMode = "HTML"
	msg.ReplyMarkup = keyboard
	h.bot.Send(msg)
}

func (h *Handler) sendCategoriesMenu(chatID int64) {
	keyboard := tgbotapi.NewInlineKeyboardMarkup()
	var rows [][]tgbotapi.InlineKeyboardButton

	for _, cat := range settings.Categories {
		rows = append(rows, tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData(fmt.Sprintf("%s %s", cat.Icon, cat.Name), fmt.Sprintf("cat_%s", cat.Name)),
		))
	}
	rows = append(rows, tgbotapi.NewInlineKeyboardRow(
		tgbotapi.NewInlineKeyboardButtonData("⬅️ Назад в настройки", "back_to_main_settings"),
	))
	keyboard.InlineKeyboard = rows

	msg := tgbotapi.NewMessage(chatID, "💬 <b>Категории сообщений</b>\n\nВыберите категорию:")
	msg.ParseMode = "HTML"
	msg.ReplyMarkup = keyboard
	h.bot.Send(msg)
}

func (h *Handler) handleCategoryButton(cb *tgbotapi.CallbackQuery) {
	catName := strings.TrimPrefix(cb.Data, "cat_")

	var cat *settings.SettingsCategory
	for i := range settings.Categories {
		if settings.Categories[i].Name == catName {
			cat = &settings.Categories[i]
			break
		}
	}

	if cat == nil {
		h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: true, Text: "Категория не найдена"})
		return
	}

	keyboard := tgbotapi.NewInlineKeyboardMarkup()
	var rows [][]tgbotapi.InlineKeyboardButton

	for _, mk := range cat.Messages {
		safeLabel := strings.ReplaceAll(mk.Label, "/", "&#47;")
		rows = append(rows, tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData(safeLabel, "edit_"+mk.Key),
		))
	}
	rows = append(rows, tgbotapi.NewInlineKeyboardRow(
		tgbotapi.NewInlineKeyboardButtonData("⬅️ Назад к категориям", "section_messages"),
	))
	keyboard.InlineKeyboard = rows

	// Delete the categories menu message
	h.bot.Request(tgbotapi.DeleteMessageConfig{
		ChatID:    cb.Message.Chat.ID,
		MessageID: cb.Message.MessageID,
	})

	msg := tgbotapi.NewMessage(cb.Message.Chat.ID, fmt.Sprintf("%s <b>%s</b>\n\nВыберите сообщение для редактирования:", cat.Icon, cat.Name))
	msg.ParseMode = "HTML"
	msg.ReplyMarkup = keyboard
	h.bot.Send(msg)

	h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})
}

func (h *Handler) sendUpdateSection(cb *tgbotapi.CallbackQuery) {
	currentCommit := ""
	installDir := ""
	if execPath, err := os.Executable(); err == nil {
		installDir = filepath.Dir(execPath)
		if data, err := os.ReadFile(filepath.Join(installDir, ".commit")); err == nil {
			currentCommit = strings.TrimSpace(string(data))
		}
	}

	currentVer := version.VersionString()
	text := fmt.Sprintf("🔄 <b>Обновление системы</b>\n\n📦 Версия: <b>v%s</b>", currentVer)
	if currentCommit != "" {
		text += fmt.Sprintf("\n🔖 Коммит: <code>%s</code>", currentCommit[:7])
	}

	commits, err := version.CheckUPCommits(currentCommit)
	if err == nil && len(commits) > 0 {
		text += fmt.Sprintf("\n🆕 Доступно обновлений: <b>%d</b>", len(commits))
		text += "\n\nНажмите кнопку ниже для обновления."

		keyboard := tgbotapi.NewInlineKeyboardMarkup(
			tgbotapi.NewInlineKeyboardRow(
				tgbotapi.NewInlineKeyboardButtonData("⬇️ Обновить", "do_update"),
			),
			tgbotapi.NewInlineKeyboardRow(
				tgbotapi.NewInlineKeyboardButtonData("⬅️ Назад в настройки", "back_to_main_settings"),
			),
		)

		msg := tgbotapi.NewMessage(cb.Message.Chat.ID, text)
		msg.ParseMode = "HTML"
		msg.ReplyMarkup = keyboard
		h.bot.Send(msg)
	} else {
		text += "\n✅ У вас последняя версия"

		keyboard := tgbotapi.NewInlineKeyboardMarkup(
			tgbotapi.NewInlineKeyboardRow(
				tgbotapi.NewInlineKeyboardButtonData("⬅️ Назад в настройки", "back_to_main_settings"),
			),
		)

		msg := tgbotapi.NewMessage(cb.Message.Chat.ID, text)
		msg.ParseMode = "HTML"
		msg.ReplyMarkup = keyboard
		h.bot.Send(msg)
	}

	h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})
}

func (h *Handler) handleBackToMainSettings(cb *tgbotapi.CallbackQuery) {
	h.mu.Lock()
	delete(h.editingAdmins, cb.Message.Chat.ID)
	h.mu.Unlock()

	h.bot.Request(tgbotapi.DeleteMessageConfig{
		ChatID:    cb.Message.Chat.ID,
		MessageID: cb.Message.MessageID,
	})
	h.sendMainSettingsMenu(cb.Message.Chat.ID)
	h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})
}

func (h *Handler) doUpdateFromSettings(cb *tgbotapi.CallbackQuery) {
	execPath, _ := os.Executable()
	installDir := filepath.Dir(execPath)
	commitFile := filepath.Join(installDir, ".commit")

	currentCommit := ""
	if data, err := os.ReadFile(commitFile); err == nil {
		currentCommit = strings.TrimSpace(string(data))
	}

	currentVer := version.VersionString()
	h.bot.Send(tgbotapi.NewMessage(cb.Message.Chat.ID, fmt.Sprintf("⏳ Проверка обновлений...\nТекущая версия: v%s", currentVer)))

	commits, err := version.CheckUPCommits(currentCommit)
	if err != nil {
		h.bot.Send(tgbotapi.NewMessage(cb.Message.Chat.ID, fmt.Sprintf("❌ %s", err.Error())))
		h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})
		return
	}

	if len(commits) == 0 {
		h.bot.Send(tgbotapi.NewMessage(cb.Message.Chat.ID, "✅ У вас последняя версия. Нет доступных обновлений [UP]."))
		h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})
		return
	}

	var summary strings.Builder
	summary.WriteString(fmt.Sprintf("📦 Найдено обновлений [UP]: %d\n\n", len(commits)))
	for i, c := range commits {
		msg := c.Message
		if len(msg) > 80 {
			msg = msg[:80] + "..."
		}
		summary.WriteString(fmt.Sprintf("%d. %s\n   Файлов: %d\n", i+1, msg, len(c.Filenames)))
	}
	summary.WriteString("\n⬇️ Загрузка изменённых файлов...")

	h.bot.Send(tgbotapi.NewMessage(cb.Message.Chat.ID, summary.String()))

	totalUpdated := 0
	totalSkipped := 0
	totalErrors := 0

	for _, commit := range commits {
		h.bot.Send(tgbotapi.NewMessage(cb.Message.Chat.ID, fmt.Sprintf("🔄 Применяю: %s", commit.Message)))

		for _, fname := range commit.Filenames {
			if !isUpdateableFile(fname) {
				totalSkipped++
				continue
			}

			content, err := version.GetFileContent(fname, commit.SHA)
			if err != nil {
				h.bot.Send(tgbotapi.NewMessage(cb.Message.Chat.ID, fmt.Sprintf("⚠️ Пропуск %s: %s", fname, err.Error())))
				totalErrors++
				continue
			}

			localPath := filepath.Join(installDir, fname)
			skip := false
			if existing, err := os.ReadFile(localPath); err == nil {
				if version.FileMD5(existing) == version.FileMD5(content) {
					skip = true
				}
			}

			if skip {
				totalSkipped++
				continue
			}

			os.MkdirAll(filepath.Dir(localPath), 0755)
			if err := os.WriteFile(localPath, content, 0644); err != nil {
				h.bot.Send(tgbotapi.NewMessage(cb.Message.Chat.ID, fmt.Sprintf("❌ Ошибка записи %s: %s", fname, err.Error())))
				totalErrors++
				continue
			}

			totalUpdated++
		}
	}

	os.WriteFile(commitFile, []byte(commits[0].SHA), 0644)

	resultMsg := fmt.Sprintf("✅ Обновление применено!\n\n"+
		"📝 Обновлено файлов: %d\n"+
		"⏭️ Пропущено (без изменений): %d\n"+
		"❌ Ошибок: %d\n\n"+
		"Текущий коммит: %s", totalUpdated, totalSkipped, totalErrors, commits[0].SHA[:7])

	h.bot.Send(tgbotapi.NewMessage(cb.Message.Chat.ID, resultMsg))

	updateScript := filepath.Join(installDir, "update.sh")
	os.Chmod(updateScript, 0755)

	cmd := exec.Command("sudo", "bash", updateScript, "--post-update")
	cmd.Stdout = nil
	cmd.Stderr = nil
	err = cmd.Start()
	if err != nil {
		h.bot.Send(tgbotapi.NewMessage(cb.Message.Chat.ID, fmt.Sprintf("❌ Ошибка запуска скрипта: %s", err.Error())))
		h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})
		return
	}
	cmd.Process.Release()

	h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})

	go func() {
		time.Sleep(3 * time.Second)
		os.Exit(0)
	}()
}

func (h *Handler) handleEditButton(cb *tgbotapi.CallbackQuery) {
	key := strings.TrimPrefix(cb.Data, "edit_")
	currentValue := h.settings.Get(key)

	label := ""
	for _, mk := range settings.AvailableMessages {
		if mk.Key == key {
			label = mk.Label
			break
		}
	}

	if currentValue == "" {
		currentValue = "(не установлено)"
	}

	preview := currentValue
	if len(preview) > 200 {
		preview = preview[:200] + "..."
	}

	safeLabel := strings.ReplaceAll(label, "/", "&#47;")
	safePreview := strings.ReplaceAll(preview, "<", "&lt;")
	safePreview = strings.ReplaceAll(safePreview, ">", "&gt;")

	text := fmt.Sprintf("📝 %s\n\n📌 Текущее значение:\n<code>%s</code>\n\n✏️ Отправьте новое сообщение для изменения:", safeLabel, safePreview)

	msg := tgbotapi.NewMessage(cb.Message.Chat.ID, text)
	msg.ParseMode = "HTML"
	h.bot.Send(msg)

	h.mu.Lock()
	h.editingAdmins[cb.Message.Chat.ID] = key
	h.mu.Unlock()

	h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})
}

func (h *Handler) handleBackToSettings(cb *tgbotapi.CallbackQuery) {
	h.mu.Lock()
	delete(h.editingAdmins, cb.Message.Chat.ID)
	h.mu.Unlock()

	h.bot.Request(tgbotapi.DeleteMessageConfig{
		ChatID:    cb.Message.Chat.ID,
		MessageID: cb.Message.MessageID,
	})
	h.sendCategoriesMenu(cb.Message.Chat.ID)
	h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})
}

func (h *Handler) handleSettingsEdit(message *tgbotapi.Message, key string) {
	newValue := message.Text

	err := h.settings.Set(key, newValue)
	if err != nil {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, "❌ Ошибка сохранения"))
		return
	}

	label := ""
	for _, mk := range settings.AvailableMessages {
		if mk.Key == key {
			label = mk.Label
			break
		}
	}

	h.mu.Lock()
	delete(h.editingAdmins, message.Chat.ID)
	h.mu.Unlock()

	response := fmt.Sprintf("✅ <b>%s</b> успешно обновлено!\n\n📌 Новое значение:\n<pre>%s</pre>", label, newValue)
	msg := tgbotapi.NewMessage(message.Chat.ID, response)
	msg.ParseMode = "HTML"
	h.bot.Send(msg)

	h.sendCategoriesMenu(message.Chat.ID)
}

func (h *Handler) handleResetSettings(message *tgbotapi.Message) {
	if message.Chat.ID != h.adminID {
		return
	}

	count := h.settings.InitDefaults()

	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, fmt.Sprintf("✅ Настройки проверены. Добавлено недостающих ключей: %d", count)))
	h.sendCategoriesMenu(message.Chat.ID)
}

func (h *Handler) handleVersion(message *tgbotapi.Message) {
	if message.Chat.ID != h.adminID {
		return
	}

	execPath, _ := os.Executable()
	installDir := filepath.Dir(execPath)
	commitFile := filepath.Join(installDir, ".commit")

	currentVer := version.VersionString()
	info := fmt.Sprintf("📦 Текущая версия: <b>v%s</b>", currentVer)

	if data, err := os.ReadFile(commitFile); err == nil {
		sha := strings.TrimSpace(string(data))
		if len(sha) >= 7 {
			info += fmt.Sprintf("\n🔖 Коммит: <code>%s</code>", sha[:7])
		}
	}

	commits, err := version.CheckUPCommits("")
	if err == nil && len(commits) > 0 {
		info += fmt.Sprintf("\n🆕 Доступно обновлений [UP]: <b>%d</b>\n\nИспользуйте /update для обновления", len(commits))
	} else {
		info += "\n✅ У вас последняя версия"
	}

	msg := tgbotapi.NewMessage(message.Chat.ID, info)
	msg.ParseMode = "HTML"
	h.bot.Send(msg)
}

func (h *Handler) sendBannedMessage(chatID int64, expiresAt time.Time, reason string) {
	remaining := time.Until(expiresAt)
	hours := int(remaining.Hours())
	minutes := int(remaining.Minutes()) % 60

	timeStr := ""
	if hours > 0 {
		timeStr += fmt.Sprintf("%d ч ", hours)
	}
	if minutes > 0 {
		timeStr += fmt.Sprintf("%d мин", minutes)
	}

	if reason == "" {
		reason = h.settings.Get("ban_no_reason_msg")
	}

	bannedMsg := h.settings.Get("banned_msg")
	bannedMsg = strings.ReplaceAll(bannedMsg, "{time}", timeStr)
	bannedMsg = strings.ReplaceAll(bannedMsg, "{reason}", reason)

	h.bot.Send(tgbotapi.NewMessage(chatID, bannedMsg))
}

func isSupportedContent(message *tgbotapi.Message) bool {
	return message.Text != "" ||
		message.Caption != "" ||
		len(message.Photo) > 0 ||
		message.Video != nil ||
		message.Document != nil ||
		message.Audio != nil
}
