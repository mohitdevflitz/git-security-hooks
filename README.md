# Git Security Hooks — Malware Guard

## What is this?

There is a malware that hides code inside your project files (like `tailwind.config.js` or `postcss.config.mjs`). It appends a very long line at the end of the file, pushed off-screen behind hundreds of spaces so you do not notice it. Then when you commit and push, that bad code goes to GitHub without you knowing.

This tool does two things:

1. **Blocks it at git.** Every commit, merge and push is checked. Bad code never reaches GitHub.
2. **Watches your whole PC in the background.** If an infected file appears anywhere on your drives, you get a desktop notification within seconds.

**It never edits your files.** It tells you what is wrong and where. You do the cleaning. (See "Why it does not clean automatically" below — this is deliberate, and was learned the hard way.)

---

## How do I use it? (Windows)

### Step 1 — Double-click `RUN-WINDOWS.bat`

A blue window appears asking "Do you want to allow this app to make changes?" — click **Yes**.

### Step 2 — Type `1` and press Enter

Wait about a minute. It does everything by itself:

- Installs Go if missing
- Builds the scanner and the watcher service
- Connects the hooks to git
- Locks its own files so malware cannot delete them
- Installs the background watcher and desktop notifications
- Tests itself and shows you whether it worked

When you see **PASS**, you are done. You never have to do this again — it starts automatically every time your PC boots.

---

## The menu

```
  1) INSTALL EVERYTHING  [start here]
     hooks + service + self-test
  2) Scan for malware
  3) Real-time watcher service (install/start/stop/remove)
  4) Desktop notifications (start/stop/test)
  5) Check status
  6) Test that blocking works
  7) STOP / START all protection
  8) Advanced (install without lockdown / re-harden)
  9) Exit
```

### 1) Install everything
First-time setup, and the fix-everything button if something breaks.

### 2) Scan for malware
Searches on demand. Asks what to search: all drives, one drive, a specific folder, or the current git repo. Writes a log you can read afterwards.

### 3) Real-time watcher service
Manage the background service that watches every drive.

```
  1) Install - WHOLE PC, report-only   [recommended]
  2) Install - WHOLE PC, alert only
  3) Install - one folder only
  4) Start        5) Stop        6) Remove
  7) View recent log
```

### 4) Desktop notifications
Start, test, check or stop the toast notifications. A test toast confirms Windows is actually allowed to show them.

### 5) Check status
Shows whether each piece is working. All green means protected.

### 6) Test that blocking works
Creates a fake bad file in a temp folder, tries to commit it, and expects **PASS**. The temp folder is deleted afterwards.

### 7) Stop / start all protection
One switch for all four pieces — watcher service, notifications, git blocking, and the self-healing guard task.

**a) STOP everything** pauses protection without uninstalling anything.
**b) START everything** resumes it.

Use this when you need to work without interruption. It pauses the guard task too — otherwise it would silently switch protection back on within 15 minutes.

### 8) Advanced
Install without the file lockdown, or re-apply the lockdown.

### 9) Exit

---

## What runs in the background

| Piece | What it is | Starts when |
|---|---|---|
| `GitSecurityWatcher` | Windows service. Watches all drives in real time via the NTFS change journal. | Boot, before login |
| `GitSecurityAlerts` | Desktop toast notifications. | Your logon |
| `GitSecurityHooksGuard` | Self-healing. Restores its own files if anything deletes them. | Boot, logon, every 15 min |
| Git hooks | Block commit / merge / push. | Every git command |

At logon you get a toast confirming protection is active — or telling you exactly what is broken if it is not.

Check them yourself any time:

```powershell
Get-Service GitSecurityWatcher | Select-Object Name, Status, StartType
Get-ScheduledTask GitSecurityAlerts, GitSecurityHooksGuard | Select-Object TaskName, State
git config --global core.hooksPath
```

---

## What happens when malware is found?

### When you try to commit or push

```
[MATCH] tailwind.config.js (global\.i="A10)
BLOCKED: commit contains known malware markers.
```

Nothing is saved. Nothing reaches GitHub.

### When the background watcher finds something

A toast appears, and the log records:

```
DETECTED: F:\myproject\src\routes\admin.routes.js
   marker : global\['!'\]\s*=
   payload: line 725, 20599 bytes, 487 leading spaces
   ORIGINAL NOT MODIFIED - nothing was copied or removed
```

The line number and byte count tell you exactly where to look.

### How to clean it

Open the file. Go to the line number given. You will see a huge line of gibberish after a long run of blank space. **Delete that whole line.** Save.

Then find out how it got in — this malware arrives through a compromised npm package:

```powershell
git log -S "global['!']" --oneline --all     # is it in your git history?
```

If that returns commits, the payload is in your history and possibly on the remote; cleaning your working copy is not enough. Also check `package.json` for suspicious `postinstall` / `preinstall` scripts, and consider deleting `node_modules` plus the lockfile and reinstalling.

### After you pull

```
WARNING: malware markers found in working tree after pull/merge
```

A warning, not a block — the code is already on your disk. When `git pull` fast-forwards there is no commit for a hook to intercept, so it reports immediately afterwards instead. Clean the file before running `npm run build` or `npm start`.

---

## When does it check?

| What you do | What happens |
|---|---|
| `git commit` | **Blocked** |
| `git merge` | **Blocked** |
| `git push` | **Blocked** |
| `git pull` | Warns immediately after |
| `git checkout` | Warns immediately after |
| `git clone` | Warns immediately after |
| `git rebase` | Warns immediately after |
| Any file written anywhere | Watcher notifies within seconds |

Works in **every project on your computer** automatically. No per-project setup.

---

## Why it does not clean automatically

It used to. On 2026-08-07 that feature corrupted about 25 files — SQLite databases, IDE chat transcripts, and its own source — because they merely *mentioned* the malware's signature text. Everything was recovered, but the lesson stands:

**A tool that edits files based on a text match will eventually edit the wrong file.**

Detection is now much stricter — the payload must be *structurally* present, appended at end of file after a long whitespace run, not just mentioned — and even then the tool only reports. There is no code path that writes to a scanned file.

It also no longer keeps copies of infected files. Since the original is never modified, the original *is* the intact copy; duplicating it just accumulated live malware in a folder for no benefit.

---

## Can malware delete this tool?

Mostly no. The files are locked to Administrators/SYSTEM, and the guard task restores anything deleted within 15 minutes.

**The honest limit:** malware with full Administrator rights can remove this, the same way it could disable your antivirus. Nothing on Windows survives that. This stops the ordinary kind — which is the kind you actually had.

---

## What this tool cannot do

**It cannot stop someone with your stolen GitHub token.** They push from their own machine; yours is never involved. Rotate credentials at `https://github.com/settings/tokens`.

**It cannot find malware it has never seen.** It matches known patterns. A new variant with different text will not match.

**It cannot clean files for you.** By design — see above.

**It does not scan inside `node_modules`.** That is where this malware usually lands first, but scanning it on every file event is too slow. Use option 2 for an on-demand scan, or reinstall from a clean lockfile.

---

## How to add a new malware pattern

Open `src/scanner.go` and `src/service/main.go` — both have a `markerPatterns` list:

```go
var markerPatterns = []string{
	`global\.i="A10`,
	`ETH_RPC_URL`,
	...
}
```

Add your pattern to both, then rebuild (PowerShell as Administrator):

```powershell
icacls "F:\FI\git-security-hooks" /grant "$($env:USERNAME):(OI)(CI)F" /T /C | Out-Null
Stop-Service GitSecurityWatcher -Force
cd F:\FI\git-security-hooks\src
go build -o ..\hooks\scanner.exe scanner.go
cd service
go build -o ..\..\hooks\watcher-service.exe .
Start-Service GitSecurityWatcher
```

**Keep patterns specific.** `String.fromCharCode(127)` was removed because it matches ordinary minified bundles — it produced constant false alarms with no diagnostic value.

---

## What is in this folder?

```
git-security-hooks/
├── README.md              this file
├── RUN-WINDOWS.bat        double-click this on Windows
├── RUN-LINUX-MAC.sh       run this on Linux or Mac
│
├── hooks/                 what runs when you use git
│   ├── pre-commit             blocks bad commits
│   ├── pre-merge-commit       blocks bad merges
│   ├── pre-push               blocks bad pushes
│   ├── post-merge             warns after pull
│   ├── post-checkout          warns after checkout or clone
│   ├── post-rewrite           warns after rebase
│   ├── scanner.exe            on-demand scanner
│   └── watcher-service.exe    background service
│
├── src/
│   ├── scanner.go         patterns for the on-demand scanner
│   └── service/           the background watcher
│
├── logs/
│   ├── watch-log.txt      every detection
│   └── reported.tsv       hashes of what has been reported (stops repeats)
│
├── windows/               Windows scripts (the menu uses these)
│   └── Alerts.ps1             desktop toast notifications
└── unix/                  Linux and Mac scripts
    └── alerts.sh              desktop notifications
```

You only ever touch `RUN-WINDOWS.bat`.

---

## Something went wrong

**"The menu says FAIL when I test"** — run option **1**.

**"I renamed or moved the folder"** — run option **1**. It fixes itself.

**"I cannot edit files in this folder"** — deliberate; they are locked. To unlock:
```powershell
icacls "F:\FI\git-security-hooks" /grant "$($env:USERNAME):(OI)(CI)F" /T /C
```
Re-run option **1** afterwards to re-lock.

**"My edits keep reverting"** — the guard task restores from `C:\GitHooksBackup` every 15 minutes. Re-run option **1** after editing so the backup matches.

**"No toast appears"** — enable notifications for Windows PowerShell in **Settings → System → Notifications**, then menu option **4 → b** to test.

**"A commit is blocked but the file is fine"**
```bash
git commit --no-verify
```
Only if you are certain. It disables the check for that one command.

---

## Honest status

### Windows — tested and working

| Situation | Expected | Result |
|---|---|---|
| Commit with bad code | Blocked | PASS |
| Commit with clean code | Allowed | PASS |
| Merge with bad code | Blocked | PASS |
| Push with bad code | Blocked | PASS |
| Checkout with bad code | Warned | PASS |
| Rebase/amend with bad code | Warned | PASS |
| Background watcher, new infected file | Detected in seconds | PASS |
| Background watcher, unchanged file on restart | Silent, no repeat | PASS |
| Detected file after report | Byte-identical, untouched | PASS |

### Bugs found and fixed on 2026-08-07

Worth recording, because two of them made the tool look like it was working when it was not:

**Auto-clean destroyed data.** It stripped "payloads" from any file containing a marker string, including SQLite databases and chat transcripts. ~25 files damaged, all recovered. Auto-clean removed entirely.

**Backups overwrote each other.** Named `timestamp-filename`, so nine files called `transcript.jsonl` in different folders collided into one. Recovered from a shadow copy. Copying removed entirely.

**Live monitoring never worked.** The USN journal read used `ReturnOnlyOnClose` without `USN_REASON_CLOSE` in the reason mask, so it silently returned nothing forever. Every "successful" detection was really the startup sweep. Meanwhile the log said `coverage is live now`. Fixed, and the startup message no longer claims more than it can prove.

**Safety checks applied to only one code path.** The extension and path filters guarded the USN path but not the sweep or fsnotify paths, so those kept modifying files after the "fix". Now a single `eligible()` gate every path must pass through.

### Linux and Mac — written but NOT tested

The code exists but has never run on a real Linux or Mac machine. Known risks:

**Line endings** — fix before first run:
```bash
sed -i'' -e 's/\r$//' RUN-LINUX-MAC.sh unix/*.sh
chmod +x RUN-LINUX-MAC.sh unix/*.sh
./RUN-LINUX-MAC.sh
```

**No USN journal** — real-time watching falls back to `fsnotify`, which is less reliable across whole drives.

**Notifications** — `unix/alerts.sh` uses `notify-send` on Linux and `osascript` on macOS, started by a systemd user unit or a launchd agent. Untested. Likely first-run problems:
- Linux: needs `libnotify-bin` (`sudo apt install libnotify-bin`) and a logind session for `systemctl --user`
- macOS: the sending binary needs notification permission in System Settings
- If the desktop path fails it prints the alert to the terminal instead, so nothing is lost silently

Test it directly with `./unix/alerts.sh --test`.

**Drive discovery** — "scan all" parses `df`, whose output varies. If it misses a drive, use the specific-folder option.

**`chattr +i`** — not supported on every filesystem. If skipped, locking is weaker but everything still works.

**Go install** — tries `apt`, `dnf`, `pacman`, Homebrew. Otherwise install from https://go.dev/dl/ first.

### Other Windows machines

- **winget missing** on older Windows 10 — install Go manually first.
- **Git Bash missing** — the hooks are shell scripts and need it. Ships with Git for Windows.
