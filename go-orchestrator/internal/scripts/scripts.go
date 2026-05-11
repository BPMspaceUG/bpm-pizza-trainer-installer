package scripts

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"pizza-trainer/go-orchestrator/internal/platform"
)

func ValidateWorkspaceRoot(root string) error {
	cleanRoot := filepath.Clean(root)
	if !hasAnyScript(cleanRoot, "00-setup.ps1", "00-setup.sh") {
		return fmt.Errorf("workspace root %q does not contain 00-setup.ps1 or 00-setup.sh", cleanRoot)
	}
	if !hasAnyDirectory(cleanRoot, "fallback-scripts", "go-orchestrator") {
		return fmt.Errorf("workspace root %q is missing fallback-scripts or go-orchestrator", cleanRoot)
	}
	return nil
}

func hasAnyScript(root string, names ...string) bool {
	for _, name := range names {
		if _, err := os.Stat(filepath.Join(root, name)); err == nil {
			return true
		}
	}
	return false
}

func hasAnyDirectory(root string, names ...string) bool {
	for _, name := range names {
		path := filepath.Join(root, name)
		info, err := os.Stat(path)
		if err == nil && info.IsDir() {
			return true
		}
	}
	return false
}

type RunOptions struct {
	Stdout io.Writer
	Stderr io.Writer
	Stdin  io.Reader
}

func RunPreflight(kind platform.Kind, root string) error {
	return RunPreflightWithOptions(kind, root, RunOptions{})
}

func RunPreflightWithOptions(kind platform.Kind, root string, options RunOptions) error {
	switch kind {
	case platform.Windows:
		return runPowerShell(root, options, "00-preflight.ps1")
	case platform.Unix:
		return runBash(root, options, "00-preflight.sh")
	default:
		return fmt.Errorf("unsupported platform kind %q", kind)
	}
}

func RunSetup(kind platform.Kind, root string, skipPreflight bool) error {
	return RunSetupWithOptions(kind, root, skipPreflight, RunOptions{})
}

func RunSetupWithOptions(kind platform.Kind, root string, skipPreflight bool, options RunOptions) error {
	return RunSetupActionWithOptions(kind, root, "full-setup", skipPreflight, nil, options)
}

func RunSetupAction(kind platform.Kind, root string, action string, skipPreflight bool, extraArgs []string) error {
	return RunSetupActionWithOptions(kind, root, action, skipPreflight, extraArgs, RunOptions{})
}

func RunSetupActionWithOptions(kind platform.Kind, root string, action string, skipPreflight bool, extraArgs []string, options RunOptions) error {
	switch kind {
	case platform.Windows:
		args := []string{}
		if skipPreflight {
			args = append(args, "-SkipPreflight")
		}
		if action != "" {
			args = append(args, "-Action", action)
		} else {
			args = append(args, "-NoGui")
		}
		args = append(args, extraArgs...)
		return runPowerShell(root, options, "00-setup.ps1", args...)
	case platform.Unix:
		args := []string{}
		if skipPreflight {
			args = append(args, "--skip-preflight")
		}
		if action != "" {
			args = append(args, "--action", action)
		}
		args = append(args, extraArgs...)
		return runBash(root, options, "00-setup.sh", args...)
	default:
		return fmt.Errorf("unsupported platform kind %q", kind)
	}
}

func RunTrainer(kind platform.Kind, root string, resume bool, resetCheckpoint bool, passthrough []string) error {
	return RunTrainerWithOptions(kind, root, resume, resetCheckpoint, passthrough, RunOptions{})
}

func RunTrainerWithOptions(kind platform.Kind, root string, resume bool, resetCheckpoint bool, passthrough []string, options RunOptions) error {
	switch kind {
	case platform.Windows:
		args := make([]string, 0, len(passthrough)+2)
		if resume {
			args = append(args, "-Resume")
		}
		if resetCheckpoint {
			args = append(args, "-ResetCheckpoint")
		}
		args = append(args, passthrough...)
		return runPowerShell(root, options, "03-setup-pizza-ml-trainer.ps1", args...)
	case platform.Unix:
		args := make([]string, 0, len(passthrough)+2)
		if resume {
			args = append(args, "--resume")
		}
		if resetCheckpoint {
			args = append(args, "--reset-checkpoint")
		}
		args = append(args, passthrough...)
		return runBash(root, options, "03-setup-pizza-ml-trainer.sh", args...)
	default:
		return fmt.Errorf("unsupported platform kind %q", kind)
	}
}

func runPowerShell(root string, options RunOptions, script string, extraArgs ...string) error {
	path := filepath.Join(root, script)
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("resolve script %s: %w", path, err)
	}
	args := []string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path}
	args = append(args, extraArgs...)
	return runCommand(options, "powershell", args...)
}

func runBash(root string, options RunOptions, script string, extraArgs ...string) error {
	path := filepath.Join(root, script)
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("resolve script %s: %w", path, err)
	}
	args := []string{path}
	args = append(args, extraArgs...)
	return runCommand(options, "bash", args...)
}

func runCommand(options RunOptions, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = options.Stdout
	if cmd.Stdout == nil {
		cmd.Stdout = os.Stdout
	}
	cmd.Stderr = options.Stderr
	if cmd.Stderr == nil {
		cmd.Stderr = os.Stderr
	}
	cmd.Stdin = options.Stdin
	if cmd.Stdin == nil {
		cmd.Stdin = os.Stdin
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("run %s: %w", name, err)
	}
	return nil
}

func RunWSLSSH(kind platform.Kind, root string) error {
	if kind != platform.Windows {
		return fmt.Errorf("wsl-ssh is only supported on Windows")
	}
	return runPowerShell(root, RunOptions{}, "01-setup-wsl-ssh.ps1")
}

func RunCodingAgents(kind platform.Kind, root string, allowRemoteInstall bool) error {
	if kind != platform.Windows {
		return fmt.Errorf("coding-agents is only supported on Windows")
	}
	args := []string{}
	if allowRemoteInstall {
		args = append(args, "-AllowRemoteScriptInstall")
	}
	return runPowerShell(root, RunOptions{}, "02-setup-coding-agents.ps1", args...)
}
