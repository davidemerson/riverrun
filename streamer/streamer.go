package main

import (
	"bufio"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/BurntSushi/toml"
)

type Config struct {
	Streamer struct {
		StorageDir   string
		StreamPort   int
		M3uDirectory string
	}
}

func loadConfig(filename string) (Config, error) {
	var config Config
	if _, err := toml.DecodeFile(filename, &config); err != nil {
		return config, err
	}
	return config, nil
}

func getOldestFile(directory string) (string, error) {
	files, err := os.ReadDir(directory)
	if err != nil {
		return "", err
	}

	sortedFiles := make([]os.DirEntry, 0, len(files))
	for _, file := range files {
		if !file.IsDir() && strings.HasSuffix(file.Name(), ".ogg") {
			sortedFiles = append(sortedFiles, file)
		}
	}

	sort.Slice(sortedFiles, func(i, j int) bool {
		iInfo, _ := sortedFiles[i].Info()
		jInfo, _ := sortedFiles[j].Info()
		return iInfo.ModTime().Before(jInfo.ModTime())
	})

	if len(sortedFiles) == 0 {
		return "", nil
	}

	return filepath.Join(directory, sortedFiles[0].Name()), nil
}

func isFileReady(filePath string) bool {
	for i := 0; i < 5; i++ {
		file, err := os.Open(filePath)
		if err == nil {
			file.Close()
			return true
		}
		log.Printf("File %s is not ready. Retrying...", filePath)
		time.Sleep(2 * time.Second)
	}
	return false
}

func getLocalIP() (string, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return "", err
	}

	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp != 0 && iface.Flags&net.FlagLoopback == 0 {
			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}

			for _, addr := range addrs {
				switch v := addr.(type) {
				case *net.IPNet:
					if v.IP.To4() != nil {
						return v.IP.String(), nil
					}
				}
			}
		}
	}

	return "", fmt.Errorf("no suitable network interface found")
}

func streamFile(w http.ResponseWriter, filePath string) error {
	file, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	header := w.Header()
	header.Set("Content-Type", "audio/ogg")
	header.Set("Content-Disposition", fmt.Sprintf("inline; filename=\"%s\"", filepath.Base(filePath)))

	_, err = bufio.NewReader(file).WriteTo(w)
	return err
}

func main() {
	// Ensure the configuration file path is provided as an argument
	if len(os.Args) < 2 {
		log.Fatalf("Usage: %s /path/to/riverrun.toml", os.Args[0])
	}

	// Get the configuration file path from the first argument
	configPath := os.Args[1]

	// Load the configuration
	config, err := loadConfig(configPath)
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// Use the configuration
	log.Printf("Loaded configuration from: %s", configPath)

	localIP, err := getLocalIP()
	if err != nil {
		log.Fatalf("Failed to determine local IP address: %v", err)
	}

	storageDir := config.Streamer.StorageDir
	streamPort := config.Streamer.StreamPort
	m3uDirectory := config.Streamer.M3uDirectory

	var mu sync.Mutex
	var lastStreamedFile string

	http.HandleFunc("/stream", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()

		for {
			filePath, err := getOldestFile(storageDir)
			if err != nil {
				log.Printf("Error reading directory: %v", err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				return
			}

			if filePath == "" {
				log.Println("No files to stream. Waiting for new files...")
				time.Sleep(5 * time.Second)
				continue
			}

			if !isFileReady(filePath) {
				log.Printf("File %s is not ready for streaming. Skipping...", filePath)
				continue
			}

			log.Printf("Streaming file: %s", filePath)
			if err := streamFile(w, filePath); err != nil {
				log.Printf("Error streaming file: %v", err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				return
			}

			if lastStreamedFile != "" {
				if err := os.Remove(lastStreamedFile); err != nil {
					log.Printf("Failed to delete previously streamed file: %v", err)
				}
			}

			lastStreamedFile = filePath
			break
		}
	})

	m3uPath := filepath.Join(m3uDirectory, "stream.m3u")
	m3uContent := fmt.Sprintf("#EXTM3U\nhttp://%s:%d/stream\n", localIP, streamPort)
	if err := os.WriteFile(m3uPath, []byte(m3uContent), 0644); err != nil {
		log.Fatalf("Failed to write M3U file: %v", err)
	}
	log.Printf("M3U file written to %s", m3uPath)

	log.Printf("Starting server on %s:%d", localIP, streamPort)
	if err := http.ListenAndServe(fmt.Sprintf("%s:%d", localIP, streamPort), nil); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}
