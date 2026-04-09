package version

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

const (
	Current = "1.0.0"
	Repo    = "Blix-Platform/UltimateTelegramConnectionBotGO"
)

type ReleaseInfo struct {
	TagName    string `json:"tag_name"`
	ZipballURL string `json:"zipball_url"`
	Name       string `json:"name"`
	Prerelease bool   `json:"prerelease"`
}

func CheckUpdate() (*ReleaseInfo, error) {
	resp, err := http.Get(fmt.Sprintf("https://api.github.com/repos/%s/releases", Repo))
	if err != nil {
		return nil, fmt.Errorf("ошибка проверки обновлений: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("GitHub API вернул статус %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("ошибка чтения ответа: %v", err)
	}

	var releases []ReleaseInfo
	if err := json.Unmarshal(body, &releases); err != nil {
		return nil, fmt.Errorf("ошибка парсинга: %v", err)
	}

	if len(releases) == 0 {
		return nil, fmt.Errorf("релизы не найдены")
	}

	var latest *ReleaseInfo
	var latestIsPre bool

	for i := range releases {
		r := &releases[i]
		if r.TagName == "" {
			continue
		}
		if latest == nil {
			latest = r
			latestIsPre = r.Prerelease
			continue
		}

		isPre := r.Prerelease
		cmp := CompareVersions(r.TagName, latest.TagName)

		if isPre && !latestIsPre {
			if cmp > 0 {
				latest = r
				latestIsPre = isPre
			}
		} else if !isPre && latestIsPre {
			if cmp >= 0 {
				latest = r
				latestIsPre = isPre
			}
		} else {
			if cmp > 0 {
				latest = r
				latestIsPre = isPre
			}
		}
	}

	if latest == nil {
		return nil, fmt.Errorf("не найдено валидных релизов")
	}

	latest.ZipballURL = fmt.Sprintf("https://github.com/%s/archive/refs/tags/%s.zip", Repo, latest.TagName)

	return latest, nil
}

func IsUpdateAvailable(latest string) bool {
	return Current != latest
}

func VersionString() string {
	return Current
}

func CompareVersions(v1, v2 string) int {
	parts1 := strings.Split(strings.TrimPrefix(v1, "v"), ".")
	parts2 := strings.Split(strings.TrimPrefix(v2, "v"), ".")

	maxLen := len(parts1)
	if len(parts2) > maxLen {
		maxLen = len(parts2)
	}

	for i := 0; i < maxLen; i++ {
		var n1, n2 int
		if i < len(parts1) {
			fmt.Sscanf(parts1[i], "%d", &n1)
		}
		if i < len(parts2) {
			fmt.Sscanf(parts2[i], "%d", &n2)
		}
		if n1 > n2 {
			return 1
		}
		if n1 < n2 {
			return -1
		}
	}
	return 0
}
