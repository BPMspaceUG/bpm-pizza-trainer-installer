package fallback

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var snapshotNameRe = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}$`)

// ValidateSnapshotName rejects names that do not match the YYYYMMDD-HHMMSS
// timestamp format produced by SaveSnapshot, preventing path traversal.
func ValidateSnapshotName(name string) error {
	if !snapshotNameRe.MatchString(name) {
		return fmt.Errorf("invalid snapshot name %q: expected format YYYYMMDD-HHMMSS", name)
	}
	return nil
}

var scriptFiles = []string{
	"00-preflight.ps1",
	"00-preflight.sh",
	"00-setup.ps1",
	"00-setup.sh",
	"01-setup-wsl-ssh.ps1",
	"02-setup-coding-agents.ps1",
	"02b-setup-cac.ps1",
	"03-setup-pizza-ml-trainer.ps1",
	"03-setup-pizza-ml-trainer.sh",
	"launch.bat",
}

func RootDir(workspaceRoot string) string {
	return filepath.Join(workspaceRoot, "fallback-scripts")
}

func SnapshotsDir(workspaceRoot string) string {
	return filepath.Join(RootDir(workspaceRoot), "snapshots")
}

func SnapshotDir(workspaceRoot, name string) string {
	return filepath.Join(SnapshotsDir(workspaceRoot), name)
}

func SaveSnapshot(workspaceRoot string, now time.Time) (string, error) {
	timestamp := now.Format("20060102-150405")
	rootFallback := RootDir(workspaceRoot)
	snapshotDir := SnapshotDir(workspaceRoot, timestamp)

	if err := os.MkdirAll(rootFallback, 0o755); err != nil {
		return "", fmt.Errorf("create fallback root: %w", err)
	}
	if err := os.MkdirAll(snapshotDir, 0o755); err != nil {
		return "", fmt.Errorf("create snapshot dir: %w", err)
	}

	for _, name := range scriptFiles {
		source := filepath.Join(workspaceRoot, name)
		if err := copyFile(source, filepath.Join(rootFallback, name)); err != nil {
			return "", err
		}
		if err := copyFile(source, filepath.Join(snapshotDir, name)); err != nil {
			return "", err
		}
	}

	return timestamp, nil
}

func RestoreSnapshot(workspaceRoot, snapshot string) error {
	sourceDir := RootDir(workspaceRoot)
	if snapshot != "" {
		if err := ValidateSnapshotName(snapshot); err != nil {
			return err
		}
		snapshotsBase := SnapshotsDir(workspaceRoot)
		resolved := filepath.Join(snapshotsBase, snapshot)
		rel, err := filepath.Rel(snapshotsBase, resolved)
		if err != nil || strings.HasPrefix(rel, "..") {
			return fmt.Errorf("snapshot %q resolves outside snapshots directory", snapshot)
		}
		sourceDir = resolved
	}

	info, err := os.Stat(sourceDir)
	if err != nil {
		return fmt.Errorf("resolve fallback source %s: %w", sourceDir, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("fallback source %s is not a directory", sourceDir)
	}

	for _, name := range scriptFiles {
		source := filepath.Join(sourceDir, name)
		destination := filepath.Join(workspaceRoot, name)
		if err := copyFile(source, destination); err != nil {
			return err
		}
	}

	return nil
}

func ListSnapshots(workspaceRoot string) ([]string, error) {
	entries, err := os.ReadDir(SnapshotsDir(workspaceRoot))
	if err != nil {
		if os.IsNotExist(err) {
			return []string{}, nil
		}
		return nil, fmt.Errorf("list snapshots: %w", err)
	}

	result := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			result = append(result, entry.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(result)))
	return result, nil
}

func copyFile(source, destination string) error {
	in, err := os.Open(source)
	if err != nil {
		return fmt.Errorf("open source %s: %w", source, err)
	}
	defer in.Close()

	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return fmt.Errorf("create destination dir for %s: %w", destination, err)
	}

	out, err := os.Create(destination)
	if err != nil {
		return fmt.Errorf("create destination %s: %w", destination, err)
	}
	defer out.Close()

	if _, err := io.Copy(out, in); err != nil {
		return fmt.Errorf("copy %s to %s: %w", source, destination, err)
	}

	return nil
}
