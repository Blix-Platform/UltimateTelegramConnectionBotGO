package version

import (
	"crypto/md5"
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

type CommitInfo struct {
	SHA       string   `json:"sha"`
	Message   string   `json:"message"`
	Filenames []string `json:"-"`
}

type GitHubCommit struct {
	SHA    string `json:"sha"`
	Commit struct {
		Message string `json:"message"`
	} `json:"commit"`
	Files []struct {
		Filename string `json:"filename"`
	} `json:"files"`
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
		return &ReleaseInfo{
			TagName:    "main",
			ZipballURL: fmt.Sprintf("https://github.com/%s/archive/refs/heads/main.zip", Repo),
			Name:       "Development",
		}, nil
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

func CheckUPCommits(currentCommit string) ([]CommitInfo, error) {
	resp, err := http.Get(fmt.Sprintf("https://api.github.com/repos/%s/commits?per_page=50", Repo))
	if err != nil {
		return nil, fmt.Errorf("ошибка проверки коммитов: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("GitHub API вернул статус %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("ошибка чтения ответа: %v", err)
	}

	var commits []GitHubCommit
	if err := json.Unmarshal(body, &commits); err != nil {
		return nil, fmt.Errorf("ошибка парсинга: %v", err)
	}

	var result []CommitInfo
	for _, c := range commits {
		if !strings.HasPrefix(c.Commit.Message, "[UP]") && !strings.HasPrefix(c.Commit.Message, "[up]") {
			continue
		}
		if c.SHA == currentCommit {
			break
		}

		// Fetch commit detail to get file list
		files, err := getCommitFiles(c.SHA)
		if err != nil {
			continue
		}

		result = append(result, CommitInfo{
			SHA:       c.SHA,
			Message:   strings.TrimSpace(strings.TrimPrefix(c.Commit.Message, "[UP]")),
			Filenames: files,
		})
	}

	return result, nil
}

func getCommitFiles(sha string) ([]string, error) {
	resp, err := http.Get(fmt.Sprintf("https://api.github.com/repos/%s/commits/%s", Repo, sha))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("статус %d", resp.StatusCode)
	}

	var detail GitHubCommit
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(body, &detail); err != nil {
		return nil, err
	}

	var filenames []string
	for _, f := range detail.Files {
		filenames = append(filenames, f.Filename)
	}
	return filenames, nil
}

func GetFileContent(filePath string, ref string) ([]byte, error) {
	url := fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/%s", Repo, ref, filePath)
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("файл %s не найден (статус %d)", filePath, resp.StatusCode)
	}

	return io.ReadAll(resp.Body)
}

func FileMD5(content []byte) string {
	return fmt.Sprintf("%x", md5.Sum(content))
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
