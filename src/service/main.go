// Git Security Hooks - Malware Watcher
//
// Cross-platform: runs as a Windows Service, a systemd service on Linux,
// or a launchd daemon on macOS.
//
// Shared logic lives here. OS-specific service plumbing is in
// service_windows.go and service_unix.go.

package main

import (
	"bufio"
	"crypto/sha256"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const serviceName = "GitSecurityWatcher"
const serviceDesc = "Git Security Hooks - Malware Watcher"

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

var markerPatterns = []string{
	// Variant 1: eth/blockscout C2 loader
	`global\.i="A10`,
	`ETH_RPC_URL`,
	`eth\.blockscout\.com/api`,
	`x-payload-b64`,
	`global\._t_s`,
	`global\._t_u`,
	`spawn\("node"`,
	// Variant 2: obfuscator.io-style loader
	`global\['!'\]\s*=`,
	`global\["!"\]\s*=`,
	`global\[_\$_[0-9a-f]+\[0\]\]\s*=\s*require`,
	// REMOVED: `String\.fromCharCode\(127\)` - far too generic. It matches
	// ordinary minified bundles (html5-qrcode, zxing-js and friends all hit
	// it), so it produced pure noise with no diagnostic value.
}

var markers []*regexp.Regexp

// The payload is always appended after a long run of whitespace.
var payloadTail = regexp.MustCompile(`(?s)\s{50,}(global\s*\[|global\s*\.\s*i\s*=).*$`)

var skipDirs = map[string]bool{
	"node_modules": true,
	".git":         true,
	"dist":         true,
	"build":        true,
	".next":        true,
	".angular":     true,
	"quarantine":   true,
	"evidence":     true,
}

func init() {
	for _, p := range markerPatterns {
		markers = append(markers, regexp.MustCompile(p))
	}
}

func scanContent(s string) string {
	for _, r := range markers {
		if r.MatchString(s) {
			return r.String()
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Watcher
// ---------------------------------------------------------------------------

type watcher struct {
	root       string
	selfDir    string
	quarantine bool
	logPath    string
	knownPath  string

	seenMu sync.Mutex
	seen   map[string]time.Time

	// Files already quarantined, keyed by "<path hash>:<content hash>".
	// Without this, every service restart re-sweeps the disk, re-detects the
	// same untouched files and writes another identical copy to quarantine.
	knownMu sync.Mutex
	known   map[string]bool
}

// knownKey identifies a specific file at a specific content state, so an
// unchanged file is only ever quarantined once - but a file that gets
// re-infected with a different payload is treated as new.
func knownKey(path string, content []byte) string {
	p := sha256.Sum256([]byte(strings.ToLower(path)))
	c := sha256.Sum256(content)
	return fmt.Sprintf("%x:%x", p[:8], c[:8])
}

// loadKnown rebuilds the set from the ledger so it survives restarts.
func (w *watcher) loadKnown() {
	w.known = make(map[string]bool)

	f, err := os.Open(w.knownPath)
	if err != nil {
		return
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		// when \t key \t path
		parts := strings.Split(sc.Text(), "\t")
		if len(parts) >= 2 && parts[1] != "" {
			w.known[parts[1]] = true
		}
	}
}

func newWatcher(root string, quarantine bool) *watcher {
	exe, _ := os.Executable()
	installRoot := filepath.Dir(filepath.Dir(exe)) // hooks/ -> install root

	logDir := filepath.Join(installRoot, "logs")

	w := &watcher{
		root:       root,
		selfDir:    installRoot,
		quarantine: quarantine,
		logPath:    filepath.Join(logDir, "watch-log.txt"),
		knownPath:  filepath.Join(logDir, "reported.tsv"),
		seen:       make(map[string]time.Time),
	}
	os.MkdirAll(logDir, 0755)
	w.loadKnown()
	return w
}

func (w *watcher) log(format string, a ...interface{}) {
	line := fmt.Sprintf("%s  %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, a...))
	fmt.Print(line)
	if f, err := os.OpenFile(w.logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644); err == nil {
		f.WriteString(line)
		f.Close()
	}
}

// executableExts are the only file types this malware can actually run from.
// The watcher can MODIFY files, so it deliberately restricts itself to these -
// a text match inside a log, transcript, database or document is not something
// we should ever be editing.
var executableExts = map[string]bool{
	".js": true, ".mjs": true, ".cjs": true,
	".ts": true, ".tsx": true, ".jsx": true,
	".mts": true, ".cts": true,
	".json": true, // package.json etc
	".vue": true, ".svelte": true,
}

// skipPathParts are locations we must never touch: our own files (which contain
// the signatures by design) and AI/IDE working data (which logs file contents
// and so can legitimately contain the payload text without being infected).
var skipPathParts = []string{
	`\node_modules\`, `\.git\`, `\dist\`, `\build\`, `\.next\`, `\.angular\`,
	`\windows\`, `\program files\`, `\programdata\`, `\appdata\local\temp\`,
	`\$recycle.bin\`, `\system volume information\`, `\go-build\`,

	`\evidence\`, `\quarantine\`, `\githooksbackup\`, `\.git-hooks-backup\`,
	`\git-security-hooks\`, `\.git-hooks-global\`,

	`\.gemini\`, `\.cursor\`, `\.vscode\`, `\.idea\`, `\.claude\`,
	`\antigravity-ide\`, `\copilot\`, `\claude_pzs8sxrjxfjjc\`,
	`\local-agent-mode-sessions\`,
}

// eligible is the single gate every scan path must pass through. Previously
// these checks lived only in the USN path, so the fsnotify and sweep paths
// happily read and modified logs and databases. Keep this as the one choke
// point - do not reimplement it per-path.
func (w *watcher) eligible(path string) bool {
	if !executableExts[strings.ToLower(filepath.Ext(path))] {
		return false
	}

	if abs, err := filepath.Abs(path); err == nil &&
		strings.HasPrefix(strings.ToLower(abs), strings.ToLower(w.selfDir)) {
		return false
	}

	lower := strings.ToLower(path)
	for _, skip := range skipPathParts {
		if strings.Contains(lower, skip) {
			return false
		}
	}
	return true
}

func (w *watcher) handle(path string, info os.FileInfo) {
	if !w.eligible(path) {
		return
	}

	content, err := os.ReadFile(path)
	if err != nil {
		return
	}

	hit := scanContent(string(content))
	if hit == "" {
		return
	}

	// A marker alone is not proof of infection - documentation, logs and this
	// project's own source all contain these strings legitimately. Only treat
	// it as a real infection if the payload is STRUCTURALLY present: appended
	// at the end of the file after a long run of whitespace, which is how this
	// malware always injects itself.
	structural := payloadTail.FindStringIndex(string(content)) != nil

	if !structural {
		w.log("MENTIONED (not infected): %s  (marker: %s) - left untouched", path, hit)
		return
	}

	// Already reported this exact file in this exact state? Say nothing.
	// The startup sweep re-walks the whole disk on every restart, so without
	// this every reboot re-reported and re-copied files the user has already
	// seen and chosen to leave alone.
	key := knownKey(path, content)
	w.knownMu.Lock()
	seen := w.known[key]
	w.knownMu.Unlock()
	if seen {
		return
	}

	// Report. Nothing is copied, moved, or edited - the log line is the output.
	//
	// There used to be a "quarantine" copy here. It only existed because this
	// service once stripped the payload in place, so a backup was the only way
	// to undo that. Now that the original is never touched, the original IS the
	// intact copy: duplicating it just accumulated live malware in a folder on
	// disk for no benefit.
	line := payloadLine(content)
	w.log("DETECTED: %s", path)
	w.log("   marker : %s", hit)
	w.log("   payload: line %d, %d bytes, %d leading spaces", line.num, line.length, line.indent)
	w.log("   ORIGINAL NOT MODIFIED - nothing was copied or removed")

	w.knownMu.Lock()
	w.known[key] = true
	w.knownMu.Unlock()
	w.recordKnown(key, path)

	// DELIBERATELY REPORT-ONLY.
	//
	// This service used to strip the payload from the original file in place.
	// That was a mistake: an automated regex edit driven by a text match will
	// eventually fire on something it shouldn't, and when it does it destroys
	// data - which is exactly what happened on 2026-08-07, when it corrupted
	// SQLite databases and chat transcripts across ~25 files.
	//
	// A detector that only reads is worth far more than one that writes.
	// Cleaning is a human decision. Do not reintroduce a write here.
}

// payloadLine locates the injected line so the log says where to look, which
// is the thing a copy of the file was really being kept for.
type lineInfo struct{ num, length, indent int }

func payloadLine(content []byte) lineInfo {
	best := lineInfo{}
	for i, l := range strings.Split(string(content), "\n") {
		if len(l) > best.length && payloadTail.MatchString(l) {
			best = lineInfo{
				num:    i + 1,
				length: len(l),
				indent: len(l) - len(strings.TrimLeft(l, " \t")),
			}
		}
	}
	return best
}

// recordKnown appends to a small ledger of hashes (no file contents) so a
// restarted service does not re-report files already seen.
func (w *watcher) recordKnown(key, path string) {
	f, err := os.OpenFile(w.knownPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	fmt.Fprintf(f, "%s\t%s\t%s\n", time.Now().Format(time.RFC3339), key, path)
	f.Close()
}

func (w *watcher) sweep(since time.Time) {
	filepath.Walk(w.root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			if skipDirs[info.Name()] {
				return filepath.SkipDir
			}
			if abs, e := filepath.Abs(path); e == nil && strings.EqualFold(abs, w.selfDir) {
				return filepath.SkipDir
			}
			return nil
		}
		if info.Size() > 20*1024*1024 {
			return nil
		}
		if info.ModTime().Before(since) {
			return nil
		}

		// Deliberately NOT recording into w.seen here. A full-machine sweep
		// visits millions of files; storing each one would balloon memory.
		// The ModTime filter above is enough to avoid rescanning.
		w.handle(path, info)
		return nil
	})
}

func (w *watcher) run(stop <-chan struct{}) {
	w.log("=== Watcher started on %s (quarantine: %v) ===", w.root, w.quarantine)

	w.sweep(time.Time{}) // first pass covers what is already there
	last := time.Now()

	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-stop:
			w.log("=== Watcher stopped ===")
			return
		case <-ticker.C:
			w.sweep(last.Add(-2 * time.Second))
			last = time.Now()
		}
	}
}

// ---------------------------------------------------------------------------

func usage() {
	fmt.Printf(`%s

  -path <folder>    watch one folder (repeatable for several)
  -all              watch the whole machine (all drives / filesystems)
  -quarantine       back up and strip the payload when found

Windows:
  watcher-service.exe install -all -quarantine
  watcher-service.exe install -path C:\projects -quarantine
  watcher-service.exe start | stop | remove

Linux / macOS  (managed by systemd / launchd):
  sudo ./unix/install-service.sh --all --quarantine

All platforms - run in this console instead of as a service:
  watcher-service debug -all -quarantine
`, serviceDesc)
}

// allRoots returns every place worth watching on this machine.
func allRoots() []string {
	var roots []string

	if os.PathSeparator == '\\' {
		// Windows: every fixed drive letter that exists
		for c := 'A'; c <= 'Z'; c++ {
			d := string(c) + `:\`
			if fi, err := os.Stat(d); err == nil && fi.IsDir() {
				roots = append(roots, d)
			}
		}
	} else {
		// Linux/macOS: start at / and let the skip-list prune system trees
		roots = append(roots, "/")
	}
	return roots
}

// multiFlag lets -path be given more than once.
type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ", ") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

func resolveRoots(paths []string, all bool) []string {
	if all {
		return allRoots()
	}
	var out []string
	for _, p := range paths {
		if abs, err := filepath.Abs(p); err == nil {
			out = append(out, abs)
		}
	}
	return out
}

func main() {
	if len(os.Args) < 2 {
		usage()
		return
	}

	cmd := os.Args[1]

	var pathFlags multiFlag
	fs := flag.NewFlagSet("", flag.ExitOnError)
	fs.Var(&pathFlags, "path", "folder to watch (repeatable)")
	allFlag := fs.Bool("all", false, "watch the whole machine")
	quarFlag := fs.Bool("quarantine", false, "back up and clean detected files")
	if len(os.Args) > 2 {
		fs.Parse(os.Args[2:])
	}

	roots := resolveRoots(pathFlags, *allFlag)

	switch cmd {

	case "debug":
		if len(roots) == 0 {
			fmt.Println("give -path <folder> or -all")
			return
		}
		w := newWatcher(roots[0], *quarFlag)
		w.runEvents(roots, make(chan struct{}))

	case "run":
		if len(roots) == 0 {
			return
		}
		w := newWatcher(roots[0], *quarFlag)
		runService(w, roots) // OS-specific

	case "install", "start", "stop", "remove":
		handleServiceCommand(cmd, pathFlags, *allFlag, *quarFlag) // OS-specific

	default:
		usage()
	}
}
