package webui

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"pizza-trainer/go-orchestrator/internal/checkpoint"
	"pizza-trainer/go-orchestrator/internal/fallback"
	"pizza-trainer/go-orchestrator/internal/platform"
	"pizza-trainer/go-orchestrator/internal/scripts"
)

//go:embed assets/*
var assets embed.FS

type Config struct {
	Root        string
	Addr        string
	OpenBrowser bool
}

type Server struct {
	rootMu    sync.RWMutex
	root      string
	kind      platform.Kind
	jobs      *jobManager
	logger    *log.Logger
	csrfToken string

	mux *http.ServeMux
}

type statusResponse struct {
	Platform       string   `json:"platform"`
	Root           string   `json:"root"`
	CheckpointPath string   `json:"checkpointPath"`
	Snapshots      []string `json:"snapshots"`
	Job            jobState `json:"job"`
}

type actionRequest struct {
	Root            string `json:"root"`
	Action          string `json:"action"`
	Snapshot        string `json:"snapshot"`
	UseFallback     bool   `json:"useFallback"`
	SkipPreflight   bool   `json:"skipPreflight"`
	Resume          bool   `json:"resume"`
	ResetCheckpoint bool   `json:"resetCheckpoint"`
	RemoveModules   bool   `json:"removeModules"`
	GitClean        bool   `json:"gitClean"`
	Reinstall       bool   `json:"reinstall"`
	RemovePythonEnv bool   `json:"removePythonEnv"`
	RemoveRepos     bool   `json:"removeRepos"`
	DryRun          bool   `json:"dryRun"`
}

type actionResponse struct {
	Accepted bool     `json:"accepted"`
	Message  string   `json:"message"`
	Job      jobState `json:"job"`
}

type jobState struct {
	Running   bool      `json:"running"`
	Name      string    `json:"name"`
	StartedAt time.Time `json:"startedAt"`
	EndedAt   time.Time `json:"endedAt"`
	ExitCode  int       `json:"exitCode"`
	Error     string    `json:"error"`
	Log       string    `json:"log"`
}

type jobManager struct {
	mu    sync.Mutex
	state jobState
}

// Launch starts the web UI server and returns the URL it is listening on.
// The server runs until ctx is cancelled, at which point it shuts down gracefully.
// The caller is responsible for blocking until shutdown is desired.
func Launch(ctx context.Context, config Config) (string, error) {
	root := filepath.Clean(config.Root)
	kind, err := platform.Detect()
	if err != nil {
		return "", err
	}

	server := &Server{
		root:      root,
		kind:      kind,
		jobs:      &jobManager{},
		logger:    log.New(io.Discard, "", 0),
		csrfToken: generateCSRFToken(),
		mux:       http.NewServeMux(),
	}
	server.routes()

	listener, err := net.Listen("tcp", config.Addr)
	if err != nil {
		return "", err
	}

	url := fmt.Sprintf("http://%s", listener.Addr().String())

	srv := &http.Server{Handler: server.mux}
	go srv.Serve(listener) //nolint:errcheck
	go func() {
		<-ctx.Done()
		shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutCtx) //nolint:errcheck
	}()

	if config.OpenBrowser {
		if err := openBrowser(url); err != nil {
			fmt.Printf("Browser open failed: %v\n", err)
		}
	}

	return url, nil
}

func (s *Server) routes() {
	fileServer := http.FileServer(http.FS(assets))
	s.mux.Handle("/assets/", http.StripPrefix("/", fileServer))
	s.mux.HandleFunc("/", s.handleIndex)
	s.mux.HandleFunc("/api/status", s.handleStatus)
	s.mux.HandleFunc("/api/token", s.handleToken)
	s.mux.HandleFunc("/api/action", s.requireActionAuth(s.handleAction))
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	data, err := assets.ReadFile("assets/index.html")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(data)
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	root := s.currentRoot()

	checkpointPath, err := checkpoint.DefaultTrainerPath(root)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	snapshots, err := fallback.ListSnapshots(root)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, statusResponse{
		Platform:       string(s.kind),
		Root:           root,
		CheckpointPath: checkpointPath,
		Snapshots:      snapshots,
		Job:            s.jobs.snapshot(),
	})
}

func generateCSRFToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(fmt.Sprintf("failed to generate CSRF token: %v", err))
	}
	return base64.URLEncoding.EncodeToString(b)
}

func (s *Server) handleToken(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"token": s.csrfToken})
}

func (s *Server) requireActionAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
			http.Error(w, "unsupported media type", http.StatusUnsupportedMediaType)
			return
		}
		if origin := r.Header.Get("Origin"); origin != "" {
			if !strings.HasPrefix(origin, "http://127.0.0.1") && !strings.HasPrefix(origin, "http://localhost") {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}
		}
		if r.Header.Get("X-CSRF-Token") != s.csrfToken {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next(w, r)
	}
}

func (s *Server) handleAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var request actionRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	root, err := s.applyRequestedRoot(request.Root)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if request.Action == "set-root" {
		writeJSON(w, http.StatusOK, actionResponse{
			Accepted: true,
			Message:  fmt.Sprintf("root set to %s", root),
			Job:      s.jobs.snapshot(),
		})
		return
	}

	err = s.jobs.start(request.Action, func(writer io.Writer) error {
		return s.runAction(root, request, writer)
	})
	if err != nil {
		writeJSON(w, http.StatusConflict, actionResponse{
			Accepted: false,
			Message:  err.Error(),
			Job:      s.jobs.snapshot(),
		})
		return
	}

	writeJSON(w, http.StatusAccepted, actionResponse{
		Accepted: true,
		Message:  fmt.Sprintf("started %s", request.Action),
		Job:      s.jobs.snapshot(),
	})
}

func (s *Server) currentRoot() string {
	s.rootMu.RLock()
	defer s.rootMu.RUnlock()
	return s.root
}

func (s *Server) setRoot(root string) {
	s.rootMu.Lock()
	defer s.rootMu.Unlock()
	s.root = root
}

func (s *Server) applyRequestedRoot(requestRoot string) (string, error) {
	cleanRoot := strings.TrimSpace(requestRoot)
	if cleanRoot == "" {
		return s.currentRoot(), nil
	}
	cleanRoot = filepath.Clean(cleanRoot)
	if err := scripts.ValidateWorkspaceRoot(cleanRoot); err != nil {
		return "", err
	}
	s.setRoot(cleanRoot)
	return cleanRoot, nil
}

func (s *Server) runAction(root string, request actionRequest, writer io.Writer) error {
	actionRoot := root
	if request.Snapshot != "" {
		if err := fallback.ValidateSnapshotName(request.Snapshot); err != nil {
			return err
		}
		actionRoot = fallback.SnapshotDir(root, request.Snapshot)
	} else if request.UseFallback {
		actionRoot = fallback.RootDir(root)
	}

	switch request.Action {
	case "preflight":
		return scripts.RunPreflightWithOptions(s.kind, actionRoot, scripts.RunOptions{Stdout: writer, Stderr: writer})
	case "packages-status", "packages-install", "packages-update", "repos-status", "repos-sync", "repos-cleanup", "full-setup", "setup":
		extraArgs := []string{}
		if request.RemoveModules {
			extraArgs = append(extraArgs, buildSetupFlag(s.kind, "remove-modules"))
		}
		if request.GitClean {
			extraArgs = append(extraArgs, buildSetupFlag(s.kind, "git-clean"))
		}
		if request.Reinstall {
			extraArgs = append(extraArgs, buildSetupFlag(s.kind, "reinstall"))
		}
		if request.RemovePythonEnv {
			extraArgs = append(extraArgs, buildSetupFlag(s.kind, "remove-python-env"))
		}
		if request.RemoveRepos {
			extraArgs = append(extraArgs, buildSetupFlag(s.kind, "remove-repos"))
		}
		if request.DryRun {
			extraArgs = append(extraArgs, buildSetupFlag(s.kind, "dry-run"))
		}
		action := request.Action
		if action == "setup" {
			action = "full-setup"
		}
		return scripts.RunSetupActionWithOptions(s.kind, actionRoot, action, request.SkipPreflight, extraArgs, scripts.RunOptions{Stdout: writer, Stderr: writer})
	case "trainer":
		return scripts.RunTrainerWithOptions(s.kind, actionRoot, request.Resume, request.ResetCheckpoint, nil, scripts.RunOptions{Stdout: writer, Stderr: writer})
	case "snapshot-save":
		name, err := fallback.SaveSnapshot(root, time.Now())
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(writer, "Saved snapshot %s\n", name)
		return err
	case "snapshot-restore":
		if err := fallback.RestoreSnapshot(root, request.Snapshot); err != nil {
			return err
		}
		if request.Snapshot == "" {
			_, _ = io.WriteString(writer, "Restored root fallback copy\n")
		} else {
			_, _ = fmt.Fprintf(writer, "Restored snapshot %s\n", request.Snapshot)
		}
		return nil
	default:
		return fmt.Errorf("unsupported action %q", request.Action)
	}
}

func (m *jobManager) start(name string, run func(io.Writer) error) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.state.Running {
		return fmt.Errorf("job %s is already running", m.state.Name)
	}

	m.state = jobState{
		Running:   true,
		Name:      name,
		StartedAt: time.Now(),
		Log:       "",
	}

	go func() {
		err := run(&stateWriter{m: m})

		m.mu.Lock()
		defer m.mu.Unlock()
		m.state.Running = false
		m.state.EndedAt = time.Now()
		if err != nil {
			m.state.ExitCode = 1
			m.state.Error = err.Error()
			if m.state.Log == "" {
				m.state.Log = err.Error()
			}
		} else {
			m.state.ExitCode = 0
			m.state.Error = ""
		}
	}()

	return nil
}

func (m *jobManager) snapshot() jobState {
	m.mu.Lock()
	defer m.mu.Unlock()
	state := m.state
	return state
}

type stateWriter struct {
	m *jobManager
}

func (sw *stateWriter) Write(p []byte) (int, error) {
	sw.m.mu.Lock()
	sw.m.state.Log += string(p)
	sw.m.mu.Unlock()
	return len(p), nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func openBrowser(url string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	return cmd.Start()
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
