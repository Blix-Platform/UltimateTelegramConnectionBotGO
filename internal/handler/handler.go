package handler

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"UltimateTelegramConnectionBotGO/internal/settings"
	"UltimateTelegramConnectionBotGO/internal/store"

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
		_, err = h.bot.Send(tgbotapi.NewMessage(userID, caption))
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
		userID = message.ReplyToMessage.From.ID
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
	if len(args) < 2 {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, "Использование: /unban <user_id>"))
		return
	}

	userID, err := strconv.ParseInt(args[1], 10, 64)
	if err != nil {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, "Неверный формат ID"))
		return
	}

	h.store.UnbanUser(userID)
	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, fmt.Sprintf("✅ Пользователь %d разблокирован", userID)))
}

func (h *Handler) handleUpdate(message *tgbotapi.Message) {
	if message.Chat.ID != h.adminID {
		return
	}

	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, "⏳ Обновление...\nБот перезапустится автоматически."))

	scriptPath := "/opt/tgbot/update.sh"
	if _, err := os.Stat(scriptPath); os.IsNotExist(err) {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, "❌ Скрипт обновления не найден.\nУбедитесь что бот установлен через install.sh"))
		return
	}

	cmd := exec.Command("sudo", "bash", scriptPath)
	cmd.Stdout = nil
	cmd.Stderr = nil
	err := cmd.Start()
	if err != nil {
		h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, fmt.Sprintf("❌ Ошибка запуска обновления: %s", err.Error())))
		return
	}

	cmd.Process.Release()

	go func() {
		time.Sleep(2 * time.Second)
		os.Exit(0)
	}()
}

func (h *Handler) handleSettings(message *tgbotapi.Message) {
	if message.Chat.ID != h.adminID {
		return
	}

	h.sendSettingsMenu(message.Chat.ID)
}

func (h *Handler) handleCallback(cb *tgbotapi.CallbackQuery) {
	if strings.HasPrefix(cb.Data, "edit_") {
		h.handleEditButton(cb)
	} else if cb.Data == "back_to_settings" {
		h.handleBackToSettings(cb)
	}
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

	h.sendSettingsMenu(cb.Message.Chat.ID)
	h.bot.Request(tgbotapi.CallbackConfig{CallbackQueryID: cb.ID, ShowAlert: false})
}

func (h *Handler) sendSettingsMenu(chatID int64) {
	keyboard := tgbotapi.NewInlineKeyboardMarkup()
	var rows [][]tgbotapi.InlineKeyboardButton

	for _, mk := range settings.AvailableMessages {
		safeLabel := strings.ReplaceAll(mk.Label, "/", "&#47;")
		rows = append(rows, tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData(safeLabel, "edit_"+mk.Key),
		))
	}
	keyboard.InlineKeyboard = rows

	msg := tgbotapi.NewMessage(chatID, "⚙️ <b>Настройки сообщений</b>\n\nВыберите сообщение для редактирования:")
	msg.ParseMode = "HTML"
	msg.ReplyMarkup = keyboard
	h.bot.Send(msg)
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

	h.sendSettingsMenu(message.Chat.ID)
}

func (h *Handler) handleResetSettings(message *tgbotapi.Message) {
	if message.Chat.ID != h.adminID {
		return
	}

	count := h.settings.InitDefaults()

	h.bot.Send(tgbotapi.NewMessage(message.Chat.ID, fmt.Sprintf("✅ Настройки проверены. Добавлено недостающих ключей: %d", count)))
	h.sendSettingsMenu(message.Chat.ID)
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
