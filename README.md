# Git Security Hooks — Malware Guard

## What is this?

There is a malware that hides code inside your project files (like `tailwind.config.js` or `postcss.config.mjs`). It adds a long line of hidden code at the end of the file. Then when you commit and push, that bad code goes to GitHub without you noticing.

This tool stops that from happening.

It checks your files every time you use git. If it finds the bad code, it stops you before anything bad reaches GitHub.

---

## How do I use it? (Windows)

### Step 1 — Open the folder

Open the `git-security-hooks` folder in File Explorer.

### Step 2 — Double-click `RUN-WINDOWS.bat`

A blue window will pop up asking "Do you want to allow this app to make changes?"

Click **Yes**.

### Step 3 — A menu appears

You will see this:

```
  1) INSTALL - set everything up  [start here]
  2) Scan for malware
  3) Check status
  4) Test that blocking works
  5) Advanced
  6) Exit
```

### Step 4 — Type `1` and press Enter

Wait about 30 seconds. It will do everything by itself:

- Install a small program it needs (Go)
- Build the scanner
- Connect the scanner to git
- Lock the files so malware cannot delete them
- Test itself and show you if it worked

When you see **PASS**, you are done.

You never have to do this again.

---

## How do I use it? (Linux or Mac)

⚠️ **Read this first.** These files were written on a Windows computer. Windows and Linux/Mac store line endings differently, so you must fix that once before anything will run. Otherwise you get an error like `bad interpreter: /bin/sh^M`.

Open a terminal in the `git-security-hooks` folder and run these **three** commands:

```bash
# 1. Fix line endings on the launcher scripts
sed -i'' -e 's/\r$//' RUN-LINUX-MAC.sh unix/*.sh

# 2. Make them runnable
chmod +x RUN-LINUX-MAC.sh unix/*.sh

# 3. Start the menu
./RUN-LINUX-MAC.sh
```

Then type `1` and press Enter.

(The installer fixes the line endings on the hook files itself — you only need to fix the launcher scripts by hand, since they have to run before the installer can do anything.)

**Note:** the Linux and Mac side has not been tested on a real machine yet. See "Honest status" at the bottom of this file.

---

## What does each menu option do?

### 1) INSTALL
Sets everything up. Use this the first time. Also use this if something breaks and you want to fix it.

### 2) Scan for malware
Searches your computer for the bad code. It will ask you what to search:

```
  1) All drives          <- searches your whole computer (slow, thorough)
  2) One drive           <- you type a letter like D
  3) A specific folder   <- you type a folder path
  4) Current git repo    <- only the project you are standing in
```

After it finishes, it saves a log file in the `git-security-hooks` folder so you can read the results later.

### 3) Check status
Shows you if everything is working. You should see all green:

```
  core.hooksPath : F:/FI/git-security-hooks/hooks
  scanner.exe    : present
  guard task     : Ready
  hooks          : all 6 present
```

If you see yellow or red, run option **1** to fix it.

### 4) Test that blocking works
Makes a fake bad file in a temporary folder and tries to commit it. If you see **PASS**, the protection is working. The temporary folder is deleted afterward.

### 5) Advanced
Only for special cases. Normal users never need this.

### 6) Exit
Closes the menu.

---

## What happens when malware is found?

### When you try to commit

```
[MATCH] tailwind.config.js (global\.i="A10)
BLOCKED: commit contains known malware markers.
```

The commit does not happen. Nothing is saved.

**What to do:** Open the file it named. Scroll to the very end. You will see a huge line of strange code after a lot of blank space. Delete that line. Save the file. Commit again.

### When you try to push

```
BLOCKED: push contains known malware markers being added.
```

The push does not happen. Nothing reaches GitHub.

**What to do:** Same as above — find the bad file, delete the bad line, then commit and push again.

### After you pull

```
WARNING: malware markers found in working tree after pull/merge
```

This is a warning, not a block. The bad code already came into your computer from GitHub.

**Why it cannot block:** When you run `git pull` and there is nothing to merge, git just moves files instantly without making a commit. There is no moment for the tool to step in. So it tells you right after instead.

**What to do:** Clean the file it named before you do anything else. Do not run `npm run build` or `npm start` until you clean it.

---

## When does it check?

| What you do | What happens |
|---|---|
| `git commit` | **Stops you** if bad code is there |
| `git merge` | **Stops you** if bad code is there |
| `git push` | **Stops you** if bad code is there |
| `git pull` | Warns you right after |
| `git checkout` | Warns you right after |
| `git clone` | Warns you right after |
| `git rebase` | Warns you right after |

It works in **every project on your computer**, automatically. You do not have to set it up per project.

---

## Can malware delete this tool?

Mostly no.

- The files are locked. Only an Administrator can change or delete them. Normal programs (and normal malware) cannot touch them.
- A hidden background job checks every 15 minutes, and also when your computer starts. If any file goes missing, it puts it back automatically from a backup copy.

**But be honest about the limit:** if malware ever gets full Administrator power on your computer, it can remove this — the same way it could turn off your antivirus. Nothing on Windows can survive that. This tool stops the normal kind of malware, which is what you actually had.

---

## What this tool cannot do

**It cannot stop someone with your stolen GitHub password or token.**
If someone steals your GitHub login, they can push directly to GitHub from their own computer. Your computer is never involved, so this tool never sees it.
👉 If you think this happened, change your GitHub password and delete your old tokens at `https://github.com/settings/tokens`.

**It cannot find brand-new malware it has never seen.**
It looks for specific known bad text. If someone writes a new version with different text, it will not match. See below for how to add new patterns.

**It cannot clean files for you.**
It only tells you which file is bad. You delete the bad line yourself.

---

## How to add a new malware pattern (only if needed)

Open `src/scanner.go`. At the top you will see a list:

```go
var markerPatterns = []string{
	`global\.i="A10`,
	`ETH_RPC_URL`,
	...
}
```

Add your new pattern as a new line in that list. Then rebuild:

**Windows** (PowerShell as Administrator, from inside the folder):
```powershell
cd src
go build -o ..\hooks\scanner.exe scanner.go
```

**Linux / Mac:**
```bash
sudo chattr -i hooks/*        # Linux only, unlocks the files
sudo chflags nouchg hooks/*   # Mac only, unlocks the files
cd src
go build -o ../hooks/scanner scanner.go
```

You do not need to run the installer again.

---

## What is in this folder?

```
git-security-hooks/
├── README.md              this file
├── RUN-WINDOWS.bat        double-click this on Windows
├── RUN-LINUX-MAC.sh       run this on Linux or Mac
│
├── hooks/                 the checks that run when you use git
│   ├── pre-commit             blocks bad commits
│   ├── pre-merge-commit       blocks bad merges
│   ├── pre-push               blocks bad pushes
│   ├── post-merge             warns after pull
│   ├── post-checkout          warns after checkout or clone
│   ├── post-rewrite           warns after rebase
│   └── scanner.exe            the program that does the searching
│
├── src/
│   └── scanner.go         the list of bad patterns lives here
│
├── windows/               Windows scripts (the menu uses these)
└── unix/                  Linux and Mac scripts
```

You only ever touch `RUN-WINDOWS.bat` or `RUN-LINUX-MAC.sh`. Everything else is used by the menu.

---

## Something went wrong — what do I do?

**"The menu says FAIL when I test"**
Run option **1** again.

**"I renamed or moved the folder"**
Run option **1** again. It fixes itself.

**"I cannot delete or edit files in this folder"**
That is on purpose — the files are locked for safety. To unlock, open PowerShell as Administrator and run:
```powershell
icacls "<this folder>" /reset /T /C
```
Then run option **1** again afterward to re-lock it.

**"A commit is blocked but I am sure the file is fine"**
You can skip the check just this once:
```bash
git commit --no-verify
```
Only do this if you are certain. It turns the protection off for that one command.

---

## Honest status — what is tested and what is not

### Windows — tested and working ✅

Verified on a real machine. All six situations were tested and behaved correctly:

| Situation | Expected | Result |
|---|---|---|
| Commit with bad code | Blocked | ✅ |
| Commit with clean code | Allowed | ✅ |
| Merge with bad code | Blocked | ✅ |
| Push with bad code | Blocked | ✅ |
| Checkout with bad code | Warned | ✅ |
| Rebase/amend with bad code | Warned | ✅ |

### Linux and Mac — written but NOT tested ⚠️

The code is there, but it has never actually been run on a Linux or Mac machine. Expect to hit small problems the first time. Known risks:

**1. Line endings** — the most likely problem. Fixed by the `sed` command in the setup steps above, and the installer also fixes the hook files automatically. But if you see `bad interpreter: ^M`, that is this.

**2. Finding your drives** — the "scan all" option lists mounted drives using `df`. The exact output of `df` varies between Linux versions and Mac. If "scan all" misses a drive, use the "specific folder" option instead, which always works.

**3. Locked files on Linux** — hardening uses `chattr +i` to lock the files. Some filesystems do not support this. If you see a message saying it was skipped, everything still works — you just get slightly weaker locking.

**4. Rebuilding after hardening** — once hardened, the files are locked. If you later edit `scanner.go` and rebuild, you must unlock first:
```bash
sudo chattr -i hooks/*        # Linux
sudo chflags nouchg hooks/*   # Mac
```

**5. Go installation** — the installer tries `apt`, `dnf`, `pacman`, or Homebrew. If you use something else, install Go yourself from https://go.dev/dl/ first, then run the menu.

**What to do:** run option **1**, then run option **4** (the self-test). If option 4 says **PASS**, everything is working. If it says FAIL, something above is the cause.

### Other Windows machines

Should work, but two things could differ:

- **winget missing** on older Windows 10 — then Go cannot auto-install. Install Go manually from https://go.dev/dl/ first.
- **Git Bash missing** — the hooks are shell scripts and need it. It comes with Git for Windows by default, so this is unlikely unless git was installed some unusual way.
