package platform

import (
	"fmt"
	"runtime"
)

type Kind string

const (
	Windows Kind = "windows"
	Unix    Kind = "unix"
)

func Detect() (Kind, error) {
	switch runtime.GOOS {
	case "windows":
		return Windows, nil
	case "linux", "darwin":
		return Unix, nil
	default:
		return "", fmt.Errorf("unsupported platform %q", runtime.GOOS)
	}
}
