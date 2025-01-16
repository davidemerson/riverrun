package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/BurntSushi/toml"
)

type ConverterConfig struct {
	AcceptedFileTypes []string `toml:"AcceptedFileTypes"`
	Bitrate           int      `toml:"Bitrate"`
	UploadDirectory   string   `toml:"UploadDirectory"`
	StreamDirectory   string   `toml:"StreamDirectory"`
}

func loadConverterConfig(filePath string) (ConverterConfig, error) {
	var config map[string]interface{}
	if _, err := toml.DecodeFile(filePath, &config); err != nil {
		return ConverterConfig{}, err
	}

	converterSection, ok := config["converter"].(map[string]interface{})
	if !ok {
		return ConverterConfig{}, fmt.Errorf("missing or invalid [converter] section in %s", filePath)
	}

	var converterConfig ConverterConfig
	if err := decodeTomlMap(converterSection, &converterConfig); err != nil {
		return ConverterConfig{}, fmt.Errorf("failed to parse [converter] section: %v", err)
	}

	return converterConfig, nil
}

func decodeTomlMap(data map[string]interface{}, result interface{}) error {
	bytesBuffer := new(bytes.Buffer)
	encoder := toml.NewEncoder(bytesBuffer)
	if err := encoder.Encode(data); err != nil {
		return err
	}

	_, err := toml.Decode(bytesBuffer.String(), result)
	return err
}

func generateUUID() (string, error) {
	uuid := make([]byte, 16)
	_, err := rand.Read(uuid)
	if err != nil {
		return "", err
	}

	// UUIDv7 format, clear version bits
	uuid[6] = (uuid[6] & 0x0f) | 0x70
	uuid[8] = (uuid[8] & 0x3f) | 0x80

	return hex.EncodeToString(uuid), nil
}

func convertFile(inputPath, outputPath string, bitrate int) error {
	cmd := exec.Command(
		"ffmpeg",
		"-i", inputPath,
		"-c:a", "libvorbis",
		"-b:a", fmt.Sprintf("%dk", bitrate),
		outputPath,
	)
	var out bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	fmt.Printf("Running command: ffmpeg -i %s -c:a libvorbis -b:a %dk %s\n", inputPath, bitrate, outputPath)
	if err := cmd.Run(); err != nil {
		fmt.Printf("FFmpeg error output: %s\n", stderr.String())
		return fmt.Errorf("conversion failed for %s", inputPath)
	}
	return nil
}

func checkFFmpegInstalled() error {
	cmd := exec.Command("ffmpeg", "-version")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg not installed or not accessible: %s", stderr.String())
	}
	return nil
}

func processFiles(config ConverterConfig) error {
	acceptedTypes := map[string]bool{}
	for _, ext := range config.AcceptedFileTypes {
		acceptedTypes[strings.ToLower(ext)] = true
	}

	uploadDir := config.UploadDirectory
	streamDir := config.StreamDirectory

	for {
		files, err := ioutil.ReadDir(uploadDir)
		if err != nil {
			return fmt.Errorf("failed to read upload directory: %v", err)
		}

		if len(files) == 0 {
			fmt.Println("No files to process. Waiting for files to appear...")
			time.Sleep(5 * time.Second)
			continue
		}

		for _, file := range files {
			if file.IsDir() {
				continue
			}

			filePath := filepath.Join(uploadDir, file.Name())
			if _, err := os.Stat(filePath); os.IsNotExist(err) {
				fmt.Printf("Input file does not exist: %s\n", filePath)
				continue
			}

			ext := strings.ToLower(filepath.Ext(file.Name()))

			if !acceptedTypes[ext] {
				fmt.Printf("Deleting unsupported file: %s\n", filePath)
				os.Remove(filePath)
				continue
			}

			uuid, err := generateUUID()
			if err != nil {
				return fmt.Errorf("failed to generate UUID: %v", err)
			}

			outputPath := filepath.Join(streamDir, uuid+".ogg")
			fmt.Printf("Converting file: %s -> %s\n", filePath, outputPath)

			if err := convertFile(filePath, outputPath, config.Bitrate); err != nil {
				fmt.Printf("Failed to convert file %s: %v\n", filePath, err)
				continue
			}

			os.Remove(filePath)
		}
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: go run main.go <config-file>")
		os.Exit(1)
	}

	configFile := os.Args[1]

	if err := checkFFmpegInstalled(); err != nil {
		fmt.Printf("Error: %v\n", err)
		os.Exit(1)
	}

	config, err := loadConverterConfig(configFile)
	if err != nil {
		fmt.Printf("Failed to load converter config: %v\n", err)
		os.Exit(1)
	}

	if err := processFiles(config); err != nil {
		fmt.Printf("Error processing files: %v\n", err)
		os.Exit(1)
	}
}
