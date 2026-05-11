//go:build windows

package tray

import (
	_ "embed"
	"os/exec"
	"syscall"

	"github.com/getlantern/systray"
)

var (
	modKernel32     = syscall.NewLazyDLL("kernel32.dll")
	procFreeConsole = modKernel32.NewProc("FreeConsole")
)

//go:embed icon.ico
var iconData []byte

// Run starts the Windows system tray icon and blocks until the user exits.
// onExit is called when the tray menu Exit item is clicked.
// FreeConsole is called first so a double-click launch from Explorer has no visible console.
func Run(url string, onExit func()) {
	procFreeConsole.Call() //nolint:errcheck
	systray.Run(func() {
		systray.SetIcon(iconData)
		systray.SetTooltip("Pizza Trainer")

		mOpen := systray.AddMenuItem("Open Control Panel", "Open in browser")
		mReopen := systray.AddMenuItem("Reopen Browser", "Reopen browser tab")
		systray.AddSeparator()
		mURL := systray.AddMenuItem("URL: "+url, "Current server address")
		mURL.Disable()
		systray.AddSeparator()
		mExit := systray.AddMenuItem("Exit", "Stop Pizza Trainer")

		go func() {
			for {
				select {
				case <-mOpen.ClickedCh:
					openBrowser(url)
				case <-mReopen.ClickedCh:
					openBrowser(url)
				case <-mExit.ClickedCh:
					systray.Quit()
				}
			}
		}()
	}, onExit)
}

func openBrowser(url string) {
	exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start() //nolint
}
