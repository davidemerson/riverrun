package main

import (
	"bufio"
	"database/sql"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type Config struct {
	AcceptedFileTypes    []string //types of files you want to see
	MetadataRetentionSec int64 // how long to keep metadata
	StorageDir           string // Place we'll put the files to play
	SegmentDuration      int    // Duration of each MPEG-DASH segment in seconds
	MPDOutputPath        string // Path to output the .mpd file
	StreamBaseURL        string // Base URL for streaming
	StreamBandwidth      int    // Bandwidth in bits per second
	StreamDuration       int    // Total media presentation duration in seconds
}

func loadConfig(configPath string) Config {
	file, err := os.Open(configPath)
	if err != nil {
		log.Fatalf("Failed to open config file: %v", err)
	}
	defer file.Close()

	config := Config{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "#") || line == "" {
			continue // Skip comments and empty lines
		}
		line = strings.Split(line, "#")[0] // Remove comments after '#'
		line = strings.TrimSpace(line)      // Trim again after removing comments
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, " ", 2)
		if len(parts) < 2 {
			log.Fatalf("Invalid config line: %s", line)
		}
		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(strings.Trim(parts[1], "[]"))
		switch key {
		case "AcceptedFileTypes":
			config.AcceptedFileTypes = strings.Split(value, ",")
		case "MetadataRetentionSec":
			fmt.Sscanf(value, "%d", &config.MetadataRetentionSec)
		case "StorageDir":
			if value == "local" {
				config.StorageDir, _ = os.Getwd()
			} else {
				config.StorageDir = value
			}
		case "SegmentDuration":
			fmt.Sscanf(value, "%d", &config.SegmentDuration)
		case "MPDOutputPath":
			if value == "local" {
				config.MPDOutputPath, _ = os.Getwd()
				config.MPDOutputPath = filepath.Join(config.MPDOutputPath, "stream.mpd")
			} else {
				config.MPDOutputPath = value
			}
		case "StreamBaseURL":
			config.StreamBaseURL = value
		case "StreamBandwidth":
			fmt.Sscanf(value, "%d", &config.StreamBandwidth)
		case "StreamDuration":
			fmt.Sscanf(value, "%d", &config.StreamDuration)
		default:
			log.Fatalf("Unknown config key: %s", key)
		}
	}

	if err := scanner.Err(); err != nil {
		log.Fatalf("Error reading config file: %v", err)
	}

	return config
}

func setupDatabase() (*sql.DB, error) {
	db, err := sql.Open("sqlite", "metadata.db")
	if err != nil {
		return nil, err
	}
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS metadata (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			filename TEXT,
			track_length INTEGER,
			track_artist TEXT,
			track_title TEXT,
			track_album TEXT,
			play_started INTEGER,
			play_ended INTEGER,
			timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
		)
	`)
	if err != nil {
		return nil, err
	}
	return db, nil
}

func getLocalIP() string {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		log.Printf("Error determining local IP: %v", err)
		return "localhost"
	}
	defer conn.Close()

	localAddr := conn.LocalAddr().(*net.UDPAddr)
	return localAddr.IP.String()
}

func getOldestFile(dir string, acceptedExtensions []string) (string, error) {
	files, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	var validFiles []os.DirEntry
	for _, file := range files {
		if !file.IsDir() {
			ext := strings.ToLower(filepath.Ext(file.Name()))
			if contains(acceptedExtensions, ext) {
				validFiles = append(validFiles, file)
			}
		}
	}
	log.Printf("Found %d valid files in %s", len(validFiles), dir)
	for _, f := range validFiles {
		log.Printf("File: %s", f.Name())
	}

	sort.Slice(validFiles, func(i, j int) bool {
		infoI, _ := validFiles[i].Info()
		infoJ, _ := validFiles[j].Info()
		return infoI.ModTime().Before(infoJ.ModTime())
	})

	if len(validFiles) > 0 {
		return filepath.Join(dir, validFiles[0].Name()), nil
	}
	return "", fmt.Errorf("no valid files found")
}

func contains(slice []string, item string) bool {
	for _, v := range slice {
		if v == item {
			return true
		}
	}
	return false
}

func generateMPD(config Config, localIP string) {
	if config.StreamBaseURL == "local" {
		config.StreamBaseURL = fmt.Sprintf("http://%s:8080/", localIP)
	}
	mpdContent := fmt.Sprintf(`<?xml version="1.0"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" minBufferTime="PT1.5S" type="static" mediaPresentationDuration="PT%dS" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011">
	<Period>
		<AdaptationSet mimeType="audio/mp4" segmentAlignment="true">
			<Representation id="audio" bandwidth="%d">
				<BaseURL>%s</BaseURL>
				<SegmentTemplate media="segment-$Number$.m4s" duration="%d"/>
			</Representation>
		</AdaptationSet>
	</Period>
</MPD>`, config.StreamDuration, config.StreamBandwidth, config.StreamBaseURL, config.SegmentDuration)

	if err := os.WriteFile(config.MPDOutputPath, []byte(mpdContent), 0644); err != nil {
		log.Fatalf("Failed to write MPD file: %v", err)
	}

	log.Printf("Generated MPD file at: %s", config.MPDOutputPath)
}

func extractMetadata(filePath string) (int, string, string, string, error) {
	// Dummy implementation for now
	// Replace with actual metadata extraction logic
	return 300, "Unknown Artist", "Unknown Title", "Unknown Album", nil
}

func streamFile(w http.ResponseWriter, filePath string) (int, string, string, string, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return 0, "", "", "", fmt.Errorf("failed to open file: %w", err)
	}
	defer file.Close()

	w.Header().Set("Content-Type", "audio/mpeg")
	_, err = io.Copy(w, file)
	if err != nil {
		return 0, "", "", "", fmt.Errorf("failed to stream file: %w", err)
	}

	// Dummy metadata for now
	return 300, "Unknown Artist", "Unknown Title", "Unknown Album", nil
}

func main() {
	if len(os.Args) < 2 {
		log.Fatalf("Usage: %s <config-file-path>", os.Args[0])
	}
	configPath := os.Args[1]
	config := loadConfig(configPath)

	db, err := setupDatabase()
	if err != nil {
		log.Fatalf("Failed to set up database: %v", err)
	}
	defer db.Close()

	localIP := getLocalIP()
	generateMPD(config, localIP)

	currentTrack, _ := getOldestFile(config.StorageDir, config.AcceptedFileTypes)
	nextTrack := ""
	files, _ := os.ReadDir(config.StorageDir)
	var validFiles []os.DirEntry
	for _, file := range files {
		if !file.IsDir() {
			ext := strings.ToLower(filepath.Ext(file.Name()))
			if contains(config.AcceptedFileTypes, ext) && file.Name() != filepath.Base(currentTrack) {
				validFiles = append(validFiles, file)
			}
		}
	}
	sort.Slice(validFiles, func(i, j int) bool {
		infoI, _ := validFiles[i].Info()
		infoJ, _ := validFiles[j].Info()
		return infoI.ModTime().Before(infoJ.ModTime())
	})
	if len(validFiles) > 0 {
		nextTrack = validFiles[0].Name()
	}

	log.Printf("Server started on: %s:8080", localIP)
	if currentTrack != "" {
		log.Printf("Now playing: %s", filepath.Base(currentTrack))
	} else {
		log.Printf("Now playing: None")
	}
	if nextTrack != "" {
		log.Printf("Next track: %s", nextTrack)
	} else {
		log.Printf("Next track: None")
	}

	http.HandleFunc("/stream", func(w http.ResponseWriter, r *http.Request) {
		filePath, err := getOldestFile(config.StorageDir, config.AcceptedFileTypes)
		if err != nil {
			http.Error(w, fmt.Sprintf("Failed to get oldest file: %v", err), http.StatusInternalServerError)
			return
		}

		playStarted := time.Now().Unix()
		trackLength, trackArtist, trackTitle, trackAlbum, err := streamFile(w, filePath)
		playEnded := time.Now().Unix()
		if err != nil {
			http.Error(w, fmt.Sprintf("Failed to stream file: %v", err), http.StatusInternalServerError)
			return
		}

		_, err = db.Exec(
			"INSERT INTO metadata (filename, track_length, track_artist, track_title, track_album, play_started, play_ended) VALUES (?, ?, ?, ?, ?, ?, ?)",
			filepath.Base(filePath), trackLength, trackArtist, trackTitle, trackAlbum, playStarted, playEnded,
		)
		if err != nil {
			log.Printf("Failed to save metadata: %v", err)
		}

		err = os.Remove(filePath)
		if err != nil {
			log.Printf("Failed to delete file: %v", err)
		}
	})

	http.HandleFunc("/segments/", func(w http.ResponseWriter, r *http.Request) {
		segmentID := strings.TrimPrefix(r.URL.Path, "/segments/")
		log.Printf("Request for segment: %s", segmentID)
		w.Header().Set("Content-Type", "video/mp4")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("This is a placeholder for segment " + segmentID))
	})

	log.Fatal(http.ListenAndServe(":8080", nil))
}
