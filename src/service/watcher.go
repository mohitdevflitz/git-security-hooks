package main

import (
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Event-based watcher. Unlike polling, this costs almost nothing regardless
// of how much of the disk is being watched - the OS pushes notifications
// (ReadDirectoryChangesW on Windows, inotify on Linux, kqueue on macOS).

// Directories never worth watching: churn constantly, contain no source, or
// are system-owned.
var noWatchDirs = map[string]bool{
	"node_modules":              true,
	".git":                      true,
	"dist":                      true,
	"build":                     true,
	".next":                     true,
	".angular":                  true,
	"quarantine":                true,
	"evidence":                  true,
	"$Recycle.Bin":              true,
	"System Volume Information": true,
	"Windows":                   true,
	"WinSxS":                    true,
	"Program Files":             true,
	"Program Files (x86)":       true,
	"ProgramData":               true,
	"AppData":                   true,
	"$WinREAgent":               true,
	"Recovery":                  true,
	"PerfLogs":                  true,
	"proc":                      true,
	"sys":                       true,
	"dev":                       true,
	"run":                       true,
	"snap":                      true,
	"Library":                   true,
	"private":                   true,
}

func (w *watcher) shouldSkipDir(path string, name string) bool {
	if noWatchDirs[name] {
		return true
	}
	if strings.HasPrefix(name, ".") && name != "." {
		// hidden dirs: skip, except we still want ordinary project folders
		if name != ".github" {
			return true
		}
	}
	// Never watch our own install folder
	if abs, err := filepath.Abs(path); err == nil && strings.EqualFold(abs, w.selfDir) {
		return true
	}
	return false
}

// addTree registers a watch on dir and every subdirectory beneath it.
func (w *watcher) addTree(fsw *fsnotify.Watcher, dir string) int {
	count := 0
	filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // unreadable dirs (permissions) - just skip
		}
		if !info.IsDir() {
			return nil
		}
		if w.shouldSkipDir(path, info.Name()) {
			return filepath.SkipDir
		}
		if err := fsw.Add(path); err == nil {
			count++
		}
		return nil
	})
	return count
}

// usnAvailable is set by usn_windows.go on Windows. On other platforms it
// stays nil and we go straight to the fsnotify path.
var usnAvailable func(w *watcher, roots []string, stop <-chan struct{}) bool

// runEvents picks the best available mechanism:
//   Windows -> NTFS USN change journal (instant startup, one handle per volume)
//   other   -> fsnotify (inotify / kqueue)
func (w *watcher) runEvents(roots []string, stop <-chan struct{}) {
	if usnAvailable != nil {
		if usnAvailable(w, roots, stop) {
			return
		}
		w.log("USN unavailable - falling back to per-directory watches")
	}
	w.runFsnotify(roots, stop)
}

// runFsnotify is the portable fallback: register a watch per directory.
func (w *watcher) runFsnotify(roots []string, stop <-chan struct{}) {
	fsw, err := fsnotify.NewWatcher()
	if err != nil {
		w.log("could not create watcher: %v - falling back to polling", err)
		w.run(stop)
		return
	}
	defer fsw.Close()

	w.log("=== Watcher started (quarantine: %v) ===", w.quarantine)

	total := 0
	for _, r := range roots {
		w.log("registering watches under %s ...", r)
		n := w.addTree(fsw, r)
		total += n
		w.log("   %d directories watched", n)
	}
	w.log("watching %d directories in total", total)

	// One initial sweep so anything already infected is caught immediately.
	for _, r := range roots {
		w.root = r
		w.sweep(time.Time{})
	}

	pending := make(map[string]time.Time)
	tick := time.NewTicker(time.Second)
	defer tick.Stop()

	for {
		select {

		case <-stop:
			w.log("=== Watcher stopped ===")
			return

		case ev, ok := <-fsw.Events:
			if !ok {
				return
			}
			if ev.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Rename) == 0 {
				continue
			}

			info, err := os.Stat(ev.Name)
			if err != nil {
				continue
			}

			// A new directory appeared - start watching it too
			if info.IsDir() {
				if !w.shouldSkipDir(ev.Name, filepath.Base(ev.Name)) {
					w.addTree(fsw, ev.Name)
				}
				continue
			}

			if info.Size() > 20*1024*1024 {
				continue
			}
			// Debounce: a single save fires several events.
			// Cap the map so a burst of activity cannot exhaust memory.
			if len(pending) < 10000 {
				pending[ev.Name] = time.Now()
			}

		case err, ok := <-fsw.Errors:
			if !ok {
				return
			}
			w.log("watch error: %v", err)

		case <-tick.C:
			// Process anything that stopped changing at least 400ms ago
			for path, t := range pending {
				if time.Since(t) < 400*time.Millisecond {
					continue
				}
				delete(pending, path)

				info, err := os.Stat(path)
				if err != nil {
					continue
				}
				w.handle(path, info)
			}
		}
	}
}
