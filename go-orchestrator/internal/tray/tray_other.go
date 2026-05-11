//go:build !windows

package tray

// Run is a no-op on non-Windows platforms; the caller blocks on ctx.Done() instead.
func Run(url string, onExit func()) {}
