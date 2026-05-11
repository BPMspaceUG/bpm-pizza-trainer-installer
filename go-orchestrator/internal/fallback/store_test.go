package fallback

import (
	"strings"
	"testing"
)

func TestValidateSnapshotName(t *testing.T) {
	valid := []string{
		"20260403-214500",
		"20000101-000000",
		"99991231-235959",
	}
	for _, name := range valid {
		if err := ValidateSnapshotName(name); err != nil {
			t.Errorf("expected %q to be valid, got: %v", name, err)
		}
	}

	invalid := []string{
		"../etc/passwd",
		"../../root",
		"20260403-214500/extra",
		"20260403_214500",
		"2026-04-03-214500",
		"",
		".",
		"..",
		"20260403-21450",  // too short
		"202604033-214500", // too long
	}
	for _, name := range invalid {
		if err := ValidateSnapshotName(name); err == nil {
			t.Errorf("expected %q to be invalid, got nil error", name)
		}
	}
}

func TestRestoreSnapshotRejectsTraversal(t *testing.T) {
	err := RestoreSnapshot(t.TempDir(), "../evil")
	if err == nil {
		t.Fatal("expected error for path-traversal snapshot name, got nil")
	}
	if !strings.Contains(err.Error(), "invalid snapshot name") {
		t.Fatalf("unexpected error message: %v", err)
	}
}
