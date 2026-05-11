package checkpoint

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

func DefaultTrainerPath(root string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve user home: %w", err)
	}

	ext := ".state"
	if runtime.GOOS == "windows" {
		ext = ".json"
	}

	_ = root
	return filepath.Join(home, ".pizza-trainer", "03-setup-pizza-ml-trainer"+ext), nil
}
