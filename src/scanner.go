package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Add new malware signatures here, then rebuild the binary.
var markerPatterns = []string{
	// --- Variant 1: eth/blockscout C2 loader ---
	`global\.i="A10`,
	`ETH_RPC_URL`,
	`eth\.blockscout\.com/api`,
	`x-payload-b64`,
	`global\._t_s`,
	`global\._t_u`,
	`spawn\("node"`,
	`_unins\.tmp`,

	// --- Variant 2: obfuscator.io-style loader ---
	// Assigns to a property literally named "!" on global - not something
	// any legitimate library does.
	`global\['!'\]\s*=`,
	`global\["!"\]\s*=`,
	// The decoder immediately hijacks require() off global.
	`global\[_\$_[0-9a-f]+\[0\]\]\s*=\s*require`,
	// Shared tell across both variants: fromCharCode(127) used as a
	// separator sentinel inside the string-shuffling decoder.
	`String\.fromCharCode\(127\)`,
}

func compile() []*regexp.Regexp {
	rs := make([]*regexp.Regexp, 0, len(markerPatterns))
	for _, m := range markerPatterns {
		rs = append(rs, regexp.MustCompile(m))
	}
	return rs
}

func scan(content string, rs []*regexp.Regexp) []string {
	var hits []string
	for _, r := range rs {
		if r.MatchString(content) {
			hits = append(hits, r.String())
		}
	}
	return hits
}

var skipDirs = map[string]bool{
	"node_modules": true,
	".git":         true,
	"dist":         true,
	"build":        true,
	".next":        true,
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: scanner -files f1 f2 ... | -stdin | -tree <root>")
		os.Exit(0)
	}

	rs := compile()
	mode := os.Args[1]
	found := false

	switch mode {
	case "-files":
		for _, f := range os.Args[2:] {
			b, err := os.ReadFile(f)
			if err != nil {
				continue
			}
			hits := scan(string(b), rs)
			if len(hits) > 0 {
				found = true
				fmt.Printf("[MATCH] %s (%s)\n", f, strings.Join(hits, ", "))
			}
		}

	case "-stdin":
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 1024*1024), 1024*1024*20)
		var added []string
		for scanner.Scan() {
			line := scanner.Text()
			if strings.HasPrefix(line, "+") && !strings.HasPrefix(line, "+++") {
				added = append(added, line)
			}
		}
		content := strings.Join(added, "\n")
		hits := scan(content, rs)
		if len(hits) > 0 {
			found = true
			fmt.Printf("[MATCH in diff] markers: %s\n", strings.Join(hits, ", "))
		}

	case "-tree":
		root := "."
		if len(os.Args) > 2 {
			root = os.Args[2]
		}

		// Skip our own installation folder. These files legitimately contain
		// the signature strings (that's the whole point of them), so scanning
		// them just produces guaranteed false positives.
		selfDir := ""
		if exe, err := os.Executable(); err == nil {
			// scanner.exe lives in <install>/hooks, so go up one level to
			// cover src/, windows/, unix/, README.md and the logs too.
			selfDir, _ = filepath.Abs(filepath.Dir(filepath.Dir(exe)))
		}

		filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			if info.IsDir() {
				if skipDirs[info.Name()] {
					return filepath.SkipDir
				}
				if selfDir != "" {
					if abs, e := filepath.Abs(path); e == nil && abs == selfDir {
						return filepath.SkipDir
					}
				}
				return nil
			}
			if info.Size() > 20*1024*1024 {
				return nil
			}
			b, err := os.ReadFile(path)
			if err != nil {
				return nil
			}
			hits := scan(string(b), rs)
			if len(hits) > 0 {
				found = true
				fmt.Printf("[MATCH] %s (%s)\n", path, strings.Join(hits, ", "))
			}
			return nil
		})

	default:
		fmt.Println("unknown mode:", mode)
	}

	if found {
		os.Exit(1)
	}
	os.Exit(0)
}
