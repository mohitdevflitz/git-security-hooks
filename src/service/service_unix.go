//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

// On Linux and macOS the process lifecycle is managed by systemd or launchd,
// so "run" just means: run in the foreground until told to stop. The init
// system handles start-at-boot, restart-on-crash, and logging.
func runService(w *watcher, roots []string) {
	stop := make(chan struct{})

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sig
		close(stop)
	}()

	w.runEvents(roots, stop)
}

// Service install/start/stop/remove are handled by unix/install-service.sh,
// which writes the systemd unit or launchd plist. Point the user there
// rather than duplicating that logic in Go.
func handleServiceCommand(cmd string, paths []string, all bool, quarantine bool) {
	fmt.Print(`On Linux/macOS, service management is handled by systemd/launchd.

Use the installer script instead:

    sudo ./unix/install-service.sh --all --quarantine        # whole machine
    sudo ./unix/install-service.sh /home/me/code --quarantine  # one folder

Then manage it with:

    Linux:  sudo systemctl {start|stop|status} gitsecurity-watcher
    macOS:  sudo launchctl {load|unload} /Library/LaunchDaemons/com.gitsecurityhooks.watcher.plist

To run it in this terminal instead:

    ./watcher-service debug -all -quarantine
`)
}
