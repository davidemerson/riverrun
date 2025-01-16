package main

import (
	"bufio"
	"bytes"
	"database/sql"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	_ "modernc.org/sqlite"
	"github.com/BurntSushi/toml"
)

type Config struct {
	Uploader struct {
		MaxUserUploadSize    int      `toml:"MaxUserUploadSize"`
		AcceptedUploadFileTypes []string `toml:"AcceptedUploadFileTypes"`
		MaxUserAirtime      int      `toml:"MaxUserAirtime"`
		SSHKeyDir           string   `toml:"SSHKeyDir"`
		AccessLog           string   `toml:"AccessLog"`
		InboundDirectory    string   `toml:"InboundDirectory"`
		StorageDirectory    string   `toml:"StorageDirectory"`
		StrikesBeforeTimeOut int      `toml:"StrikesBeforeTimeOut"`
		TimeOutsBeforeBan   int      `toml:"TimeOutsBeforeBan"`
	}
}

// Define UserData struct
type UserData struct {
	Strikes     int
	Timeouts    int
	DailyUpload int
	DailyAirtime int
	LastUpload  time.Time
}

var config Config
var db *sql.DB

func loadConfig(configPath string) {
	if _, err := toml.DecodeFile(configPath, &config); err != nil {
		log.Fatalf("Error loading config file: %v", err)
	}
}

func initDatabase() {
	var err error
	db, err = sql.Open("sqlite", "userstats.db")
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS user_stats (
			user TEXT PRIMARY KEY,
			strikes INTEGER DEFAULT 0,
			timeouts INTEGER DEFAULT 0,
			daily_upload INTEGER DEFAULT 0,
			daily_airtime INTEGER DEFAULT 0,
			last_upload TIMESTAMP
		)`)
	if err != nil {
		log.Fatalf("Failed to create table: %v", err)
	}
}

func logAction(user, action string) {
	logFile := filepath.Join(config.Uploader.AccessLog, "access.log")
	entry := fmt.Sprintf("%s - %s: %s\n", time.Now().Format(time.RFC3339), user, action)
	if err := ioutil.WriteFile(logFile, []byte(entry), os.ModeAppend); err != nil {
		log.Printf("Failed to log action: %v", err)
	}
}

func checkFileType(fileName string) bool {
	ext := filepath.Ext(fileName)
	for _, allowedType := range config.Uploader.AcceptedUploadFileTypes {
		if strings.EqualFold(ext, allowedType) {
			return true
		}
	}
	return false
}

func calculateFileSize(filePath string) (int, error) {
	fileInfo, err := os.Stat(filePath)
	if err != nil {
		return 0, err
	}
	return int(fileInfo.Size() / (1024 * 1024)), nil // Convert to MB
}

func calculateAudioDuration(filePath string) (int, error) {
	cmd := exec.Command("ffprobe", "-i", filePath, "-show_entries", "format=duration", "-v", "quiet", "-of", "csv=p=0")
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return 0, err
	}
	duration := 0
	fmt.Sscanf(out.String(), "%f", &duration)
	return int(duration), nil
}

func getUserData(user string) (*UserData, error) {
	row := db.QueryRow("SELECT strikes, timeouts, daily_upload, daily_airtime, last_upload FROM user_stats WHERE user = ?", user)
	userData := &UserData{}
	var lastUpload sql.NullTime
	if err := row.Scan(&userData.Strikes, &userData.Timeouts, &userData.DailyUpload, &userData.DailyAirtime, &lastUpload); err != nil {
		if err == sql.ErrNoRows {
			_, err := db.Exec("INSERT INTO user_stats (user) VALUES (?)", user)
			if err != nil {
				return nil, err
			}
			userData = &UserData{}
		} else {
			return nil, err
		}
	}
	if lastUpload.Valid {
		userData.LastUpload = lastUpload.Time
	}
	return userData, nil
}

func updateUserData(user string, userData *UserData) error {
	_, err := db.Exec(
		`UPDATE user_stats SET strikes = ?, timeouts = ?, daily_upload = ?, daily_airtime = ?, last_upload = ? WHERE user = ?`,
		userData.Strikes, userData.Timeouts, userData.DailyUpload, userData.DailyAirtime, userData.LastUpload, user,
	)
	return err
}

func parseSSHLogLine(line string) (string, string, error) {
	re := regexp.MustCompile(`Accepted publickey for \S+.*SHA256:(\S+).*scp:\s+'([^']+)'`)
	matches := re.FindStringSubmatch(line)
	if len(matches) < 3 {
		return "", "", fmt.Errorf("failed to parse SSH log line: %s", line)
	}
	fingerprint := matches[1]
	filePath := matches[2]
	return fingerprint, filePath, nil
}

func monitorSSHLogs(logFile string) {
	file, err := os.Open(logFile)
	if err != nil {
		log.Fatalf("Failed to open SSH log file: %v", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()

		if strings.Contains(line, "scp") && strings.Contains(line, "Accepted publickey") {
			fingerprint, filePath, err := parseSSHLogLine(line)
			if err != nil {
				log.Printf("Failed to parse log line: %v", err)
				continue
			}

			processUpload(filepath.Join(config.Uploader.SSHKeyDir, fingerprint), filePath)
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("Error reading SSH log file: %v", err)
	}
}

func processUpload(sshKeyPath, filePath string) {
	fingerprint, err := fingerprintSSHKey(sshKeyPath)
	if err != nil {
		log.Printf("Error calculating SSH key fingerprint: %v", err)
		return
	}

	userData, err := getUserData(fingerprint)
	if err != nil {
		log.Printf("Error fetching user data: %v", err)
		return
	}

	if !checkFileType(filePath) {
		userData.Strikes++
		logAction(fingerprint, "Attempted to upload unsupported file type")
		if userData.Strikes >= config.Uploader.StrikesBeforeTimeOut {
			timeOutUser(fingerprint, userData)
		}
		_ = updateUserData(fingerprint, userData)
		return
	}

	fileSize, err := calculateFileSize(filePath)
	if err != nil {
		log.Printf("Error calculating file size: %v", err)
		return
	}

	if userData.DailyUpload+fileSize > config.Uploader.MaxUserUploadSize {
		userData.Strikes++
		logAction(fingerprint, "Exceeded daily upload size limit")
		if userData.Strikes >= config.Uploader.StrikesBeforeTimeOut {
			timeOutUser(fingerprint, userData)
		}
		_ = updateUserData(fingerprint, userData)
		return
	}

	duration, err := calculateAudioDuration(filePath)
	if err != nil {
		log.Printf("Error calculating audio duration: %v", err)
		return
	}

	if userData.DailyAirtime+duration > config.Uploader.MaxUserAirtime {
		userData.Strikes++
		logAction(fingerprint, "Exceeded daily airtime limit")
		if userData.Strikes >= config.Uploader.StrikesBeforeTimeOut {
			timeOutUser(fingerprint, userData)
		}
		_ = updateUserData(fingerprint, userData)
		return
	}

	userData.DailyUpload += fileSize
	userData.DailyAirtime += duration
	userData.LastUpload = time.Now()

	destPath := filepath.Join(config.Uploader.StorageDirectory, filepath.Base(filePath))
	if err := os.Rename(filePath, destPath); err != nil {
		log.Printf("Error moving file to storage directory: %v", err)
		return
	}

	logAction(fingerprint, "File uploaded successfully")
	_ = updateUserData(fingerprint, userData)
}

func timeOutUser(user string, userData *UserData) {
	userData.Timeouts++
	userData.Strikes = 0
	if userData.Timeouts >= config.Uploader.TimeOutsBeforeBan {
		banUser(user)
		return
	}
	logAction(user, "User timed out")
	_ = updateUserData(user, userData)
}

func banUser(user string) {
	_, err := db.Exec("DELETE FROM user_stats WHERE user = ?", user)
	if err != nil {
		log.Printf("Failed to delete user from database: %v", err)
	}
	logAction(user, "User banned")
}

func main() {
	if len(os.Args) < 2 {
		log.Fatalf("Usage: %s <config-file>", os.Args[0])
	}

	configPath := os.Args[1]
	loadConfig(configPath)
	initDatabase()
	defer db.Close()

	log.Println("Server started and monitoring uploads...")
	go monitorInboundDirectory()
	go monitorSSHLogs("/var/log/auth.log") // Adjust log file path as needed

	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.SplitN(line, " ", 2)
		if len(parts) != 2 {
			continue
		}
		sshKeyPath, filePath := parts[0], parts[1]
		processUpload(sshKeyPath, filePath)
	}

	if err := scanner.Err(); err != nil {
		log.Printf("Error reading input: %v", err)
	}
}
