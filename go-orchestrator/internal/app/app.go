package app

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"pizza-trainer/go-orchestrator/internal/checkpoint"
	"pizza-trainer/go-orchestrator/internal/fallback"
	"pizza-trainer/go-orchestrator/internal/platform"
	"pizza-trainer/go-orchestrator/internal/scripts"
	"pizza-trainer/go-orchestrator/internal/tray"
	"pizza-trainer/go-orchestrator/internal/webui"
)

func Run(args []string) error {
	if len(args) == 0 {
		return runUITray()
	}

	switch args[0] {
	case "preflight":
		return runPreflight(args[1:])
	case "setup":
		return runSetup(args[1:])
	case "full-setup":
		return runFullSetup(args[1:])
	case "trainer":
		return runTrainer(args[1:])
	case "packages-status":
		return runPackagesStatus(args[1:])
	case "packages-install":
		return runPackagesInstall(args[1:])
	case "packages-update":
		return runPackagesUpdate(args[1:])
	case "repos-status":
		return runReposStatus(args[1:])
	case "repos-sync":
		return runReposSync(args[1:])
	case "repos-cleanup":
		return runReposCleanup(args[1:])
	case "wsl-ssh":
		return runWSLSSH(args[1:])
	case "coding-agents":
		return runCodingAgents(args[1:])
	case "validate":
		return runValidate(args[1:])
	case "checkpoint-path":
		return printCheckpointPath(args[1:])
	case "snapshot-save":
		return runSnapshotSave(args[1:])
	case "snapshot-restore":
		return runSnapshotRestore(args[1:])
	case "snapshot-list":
		return runSnapshotList(args[1:])
	case "ui":
		return runUI(args[1:])
	case "help", "-h", "--help":
		fmt.Println(usageText())
		return nil
	default:
		return fmt.Errorf("unknown command %q\n\n%s", args[0], usageText())
	}
}

func runPreflight(args []string) error {
	fs := flag.NewFlagSet("preflight", flag.ContinueOnError)
	root := fs.String("root", ".", "workspace root containing the setup scripts")
	fallback := fs.Bool("fallback", false, "run against fallback-scripts instead of the active top-level scripts")
	snapshot := fs.String("snapshot", "", "run against fallback-scripts/snapshots/<name>")
	if err := fs.Parse(args); err != nil {
		return err
	}
	scriptsRoot, err := resolveScriptsRoot(filepath.Clean(*root), *fallback, *snapshot)
	if err != nil {
		return err
	}

	plt, err := platform.Detect()
	if err != nil {
		return err
	}
	return scripts.RunPreflight(plt, scriptsRoot)
}

func runSetup(args []string) error {
	return runFullSetup(args)
}

func runFullSetup(args []string) error {
	fs := flag.NewFlagSet("setup", flag.ContinueOnError)
	root := fs.String("root", ".", "workspace root containing the setup scripts")
	skipPreflight := fs.Bool("skip-preflight", false, "skip script preflight checks")
	dryRun := fs.Bool("dry-run", false, "show what full setup would do without changing repos or installing packages")
	pizzaRepoURL := fs.String("pizza-repo-url", "", "optional repository URL used when pizza-ml has not been cloned yet")
	fallback := fs.Bool("fallback", false, "run against fallback-scripts instead of the active top-level scripts")
	snapshot := fs.String("snapshot", "", "run against fallback-scripts/snapshots/<name>")
	if err := fs.Parse(args); err != nil {
		return err
	}
	scriptsRoot, err := resolveScriptsRoot(filepath.Clean(*root), *fallback, *snapshot)
	if err != nil {
		return err
	}

	plt, err := platform.Detect()
	if err != nil {
		return err
	}
	extraArgs := []string{}
	if *dryRun {
		extraArgs = append(extraArgs, buildSetupFlag(plt, "dry-run"))
	}
	if *pizzaRepoURL != "" {
		extraArgs = append(extraArgs, buildSetupArg(plt, "pizza-repo-url"), *pizzaRepoURL)
	}
	return scripts.RunSetupAction(plt, scriptsRoot, "full-setup", *skipPreflight, extraArgs)
}

func runTrainer(args []string) error {
	fs := flag.NewFlagSet("trainer", flag.ContinueOnError)
	root := fs.String("root", ".", "workspace root containing the setup scripts")
	resume := fs.Bool("resume", false, "resume from the last trainer checkpoint")
	resetCheckpoint := fs.Bool("reset-checkpoint", false, "reset the saved trainer checkpoint before running")
	fallback := fs.Bool("fallback", false, "run against fallback-scripts instead of the active top-level scripts")
	snapshot := fs.String("snapshot", "", "run against fallback-scripts/snapshots/<name>")
	if err := fs.Parse(args); err != nil {
		return err
	}
	scriptsRoot, err := resolveScriptsRoot(filepath.Clean(*root), *fallback, *snapshot)
	if err != nil {
		return err
	}

	plt, err := platform.Detect()
	if err != nil {
		return err
	}
	return scripts.RunTrainer(plt, scriptsRoot, *resume, *resetCheckpoint, fs.Args())
}

func runValidate(args []string) error {
	if len(args) > 0 {
		return errors.New("validate does not accept positional arguments")
	}
	return runPreflight(nil)
}

func printCheckpointPath(args []string) error {
	fs := flag.NewFlagSet("checkpoint-path", flag.ContinueOnError)
	root := fs.String("root", ".", "workspace root containing the setup scripts")
	if err := fs.Parse(args); err != nil {
		return err
	}

	path, err := checkpoint.DefaultTrainerPath(filepath.Clean(*root))
	if err != nil {
		return err
	}
	fmt.Println(path)
	return nil
}

func runSnapshotSave(args []string) error {
	fs := flag.NewFlagSet("snapshot-save", flag.ContinueOnError)
	root := fs.String("root", ".", "workspace root containing the setup scripts")
	if err := fs.Parse(args); err != nil {
		return err
	}

	name, err := fallback.SaveSnapshot(filepath.Clean(*root), time.Now())
	if err != nil {
		return err
	}
	fmt.Println(name)
	return nil
}

func runSnapshotRestore(args []string) error {
	fs := flag.NewFlagSet("snapshot-restore", flag.ContinueOnError)
	root := fs.String("root", ".", "workspace root containing the setup scripts")
	snapshot := fs.String("snapshot", "", "dated snapshot name under fallback-scripts/snapshots; restore root fallback copy if empty")
	if err := fs.Parse(args); err != nil {
		return err
	}

	return fallback.RestoreSnapshot(filepath.Clean(*root), *snapshot)
}

func runSnapshotList(args []string) error {
	fs := flag.NewFlagSet("snapshot-list", flag.ContinueOnError)
	root := fs.String("root", ".", "workspace root containing the setup scripts")
	if err := fs.Parse(args); err != nil {
		return err
	}

	entries, err := fallback.ListSnapshots(filepath.Clean(*root))
	if err != nil {
		return err
	}
	for _, entry := range entries {
		fmt.Println(entry)
	}
	return nil
}

func runPackagesStatus(args []string) error {
	return runSetupActionCommand("packages-status", args, nil)
}

func runPackagesInstall(args []string) error {
	return runSetupActionCommand("packages-install", args, nil)
}

func runPackagesUpdate(args []string) error {
	return runSetupActionCommand("packages-update", args, nil)
}

func runReposStatus(args []string) error {
	return runSetupActionCommand("repos-status", args, nil)
}

func runReposSync(args []string) error {
	return runSetupActionCommand("repos-sync", args, nil)
}

func runReposCleanup(args []string) error {
	return runSetupActionCommand("repos-cleanup", args, func(fs *flag.FlagSet, plt platform.Kind) []string {
		removeModules := fs.Bool("remove-modules", false, "remove node_modules directories")
		gitClean := fs.Bool("git-clean", false, "run git clean -fd in repositories")
		reinstall := fs.Bool("reinstall", false, "re-run detected package manager install after cleanup")
		removePythonEnv := fs.Bool("remove-python-env", false, "remove pizza-ml venv, data, and top-level .pth files")
		removeRepos := fs.Bool("remove-repos", false, "delete cloned repository directories")
		_ = removeModules
		_ = gitClean
		_ = reinstall
		_ = removePythonEnv
		_ = removeRepos
		return nil
	})
}

func runWSLSSH(args []string) error {
	fs := flag.NewFlagSet("wsl-ssh", flag.ContinueOnError)
	root := fs.String("root", ".", "workspace root containing the setup scripts")
	if err := fs.Parse(args); err != nil {
		return err
	}
	plt, err := platform.Detect()
	if err != nil {
		return err
	}
	return scripts.RunWSLSSH(plt, filepath.Clean(*root))
}

func runCodingAgents(args []string) error {
	fs := flag.NewFlagSet("coding-agents", flag.ContinueOnError)
	root := fs.String("root", ".", "workspace root containing the setup scripts")
	allowRemoteInstall := fs.Bool("allow-remote-script-install", false, "allow remote installer script execution where required")
	only := fs.String("only", "all", "which part to run: all, extensions, or cac")
	if err := fs.Parse(args); err != nil {
		return err
	}
	plt, err := platform.Detect()
	if err != nil {
		return err
	}
	return scripts.RunCodingAgents(plt, filepath.Clean(*root), *allowRemoteInstall, *only)
}

func runSetupActionCommand(action string, args []string, configure func(fs *flag.FlagSet, plt platform.Kind) []string) error {
	fs := flag.NewFlagSet(action, flag.ContinueOnError)
	root := fs.String("root", ".", "workspace root containing the setup scripts")
	skipPreflight := fs.Bool("skip-preflight", false, "skip script preflight checks")
	pizzaRepoURL := fs.String("pizza-repo-url", "", "optional repository URL used when pizza-ml has not been cloned yet")
	fallback := fs.Bool("fallback", false, "run against fallback-scripts instead of the active top-level scripts")
	snapshot := fs.String("snapshot", "", "run against fallback-scripts/snapshots/<name>")
	dryRun := fs.Bool("dry-run", false, "show what the action would do without changing repositories where supported")
	if configure != nil {
		configure(fs, "")
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	scriptsRoot, err := resolveScriptsRoot(filepath.Clean(*root), *fallback, *snapshot)
	if err != nil {
		return err
	}
	plt, err := platform.Detect()
	if err != nil {
		return err
	}
	extraArgs := []string{}
	if *pizzaRepoURL != "" {
		extraArgs = append(extraArgs, buildSetupArg(plt, "pizza-repo-url"), *pizzaRepoURL)
	}
	if *dryRun {
		extraArgs = append(extraArgs, buildSetupFlag(plt, "dry-run"))
	}
	switch action {
	case "repos-cleanup":
		if fs.Lookup("remove-modules").Value.String() == "true" {
			extraArgs = append(extraArgs, buildSetupFlag(plt, "remove-modules"))
		}
		if fs.Lookup("git-clean").Value.String() == "true" {
			extraArgs = append(extraArgs, buildSetupFlag(plt, "git-clean"))
		}
		if fs.Lookup("reinstall").Value.String() == "true" {
			extraArgs = append(extraArgs, buildSetupFlag(plt, "reinstall"))
		}
		if fs.Lookup("remove-python-env").Value.String() == "true" {
			extraArgs = append(extraArgs, buildSetupFlag(plt, "remove-python-env"))
		}
		if fs.Lookup("remove-repos").Value.String() == "true" {
			extraArgs = append(extraArgs, buildSetupFlag(plt, "remove-repos"))
		}
	}
	return scripts.RunSetupAction(plt, scriptsRoot, action, *skipPreflight, extraArgs)
}

func buildSetupFlag(kind platform.Kind, name string) string {
	if kind == platform.Windows {
		switch name {
		case "remove-modules":
			return "-RemoveModules"
		case "git-clean":
			return "-GitClean"
		case "reinstall":
			return "-Reinstall"
		case "remove-python-env":
			return "-RemovePythonEnv"
		case "remove-repos":
			return "-RemoveRepos"
		case "dry-run":
			return "-DryRun"
		}
	}
	return "--" + name
}

func buildSetupArg(kind platform.Kind, name string) string {
	if kind == platform.Windows {
		switch name {
		case "pizza-repo-url":
			return "-PizzaRepoUrl"
		}
	}
	return "--" + name
}

// runUITray is called for the no-argument launch path.
// It starts the web server and manages its lifecycle via a Windows system tray icon.
// On non-Windows platforms the tray is a no-op and the process exits on Ctrl+C.
func runUITray() error {
	selectedRoot := defaultUIRoot()
	if err := scripts.ValidateWorkspaceRoot(selectedRoot); err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	url, err := webui.Launch(ctx, webui.Config{
		Root:        selectedRoot,
		Addr:        "127.0.0.1:0",
		OpenBrowser: true,
	})
	if err != nil {
		return err
	}

	tray.Run(url, stop) // blocks on Windows until tray Exit is clicked
	<-ctx.Done()
	return nil
}

func runUI(args []string) error {
	fs := flag.NewFlagSet("ui", flag.ContinueOnError)
	root := fs.String("root", defaultUIRoot(), "workspace root containing the setup scripts; auto-detected when omitted")
	addr := fs.String("addr", "127.0.0.1:0", "listen address for the local UI server")
	openBrowser := fs.Bool("open", true, "open the local UI automatically in the default browser")
	if err := fs.Parse(args); err != nil {
		return err
	}
	selectedRoot := filepath.Clean(*root)
	if err := scripts.ValidateWorkspaceRoot(selectedRoot); err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	url, err := webui.Launch(ctx, webui.Config{
		Root:        selectedRoot,
		Addr:        *addr,
		OpenBrowser: *openBrowser,
	})
	if err != nil {
		return err
	}
	fmt.Printf("UI available at %s (Ctrl+C to stop)\n", url)
	<-ctx.Done()
	return nil
}

func defaultUIRoot() string {
	candidates := []string{}
	if exePath, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exePath)
		candidates = append(candidates, exeDir, filepath.Dir(exeDir), filepath.Dir(filepath.Dir(exeDir)))
	}
	if workingDir, err := os.Getwd(); err == nil {
		candidates = append(candidates, workingDir, filepath.Dir(workingDir), filepath.Dir(filepath.Dir(workingDir)))
	}
	for _, candidate := range candidates {
		cleanCandidate := filepath.Clean(candidate)
		if err := scripts.ValidateWorkspaceRoot(cleanCandidate); err == nil {
			return cleanCandidate
		}
	}
	return "."
}

func usageError() error {
	return errors.New(usageText())
}

func usageText() string {
	return `pizza-trainer wraps the stabilized training setup scripts.

Running pizza-trainer with no command launches the local browser UI using an auto-detected workspace root.

Commands:
  preflight         Run the platform-specific preflight script
	setup             Run non-interactive full setup (packages + repos)
	full-setup        Run non-interactive full setup (packages + repos)
	packages-status   Show package status
	packages-install  Install all missing packages
	packages-update   Update installed packages (manifest only, never system-wide)
	repos-status      Show repository status
	repos-sync        Clone or update repositories
	repos-cleanup     Clean repositories or delete cloned repos with explicit flags
	wsl-ssh           Run the Windows WSL/SSH setup script
	coding-agents     Run the Windows coding-agents setup scripts (--only all|extensions|cac)
  trainer           Run the trainer setup entrypoint
  validate          Alias for preflight for now
  checkpoint-path   Print the default trainer checkpoint path
	snapshot-save     Save a dated fallback snapshot and refresh fallback-scripts
	snapshot-restore  Restore active scripts from fallback-scripts or a named snapshot
	snapshot-list     List dated fallback snapshots
	ui                Launch the local browser control panel

Examples:
	pizza-trainer
  pizza-trainer preflight --root ..
	pizza-trainer preflight --root .. --fallback
	pizza-trainer setup --root .. --snapshot 20260403-214500
	pizza-trainer packages-status --root ..
	pizza-trainer repos-status --root ..
	pizza-trainer repos-cleanup --root .. --remove-modules --dry-run
	pizza-trainer repos-cleanup --root .. --remove-repos
	pizza-trainer setup --root ..
	pizza-trainer trainer --root .. --resume -- --skip-test
	pizza-trainer snapshot-save --root ..
	pizza-trainer snapshot-list --root ..
	pizza-trainer snapshot-restore --root .. --snapshot 20260403-214500
	pizza-trainer ui --root ..`
}

func resolveScriptsRoot(root string, useFallback bool, snapshot string) (string, error) {
	if snapshot != "" {
		if err := fallback.ValidateSnapshotName(snapshot); err != nil {
			return "", err
		}
		return filepath.Join(root, "fallback-scripts", "snapshots", snapshot), nil
	}
	if useFallback {
		return filepath.Join(root, "fallback-scripts"), nil
	}
	return root, nil
}
