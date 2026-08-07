//go:build windows

package main

// NTFS USN Change Journal watcher.
//
// Instead of registering a watch on every directory (slow to set up, heavy on
// memory, misses folders created later), this opens ONE handle per volume and
// reads the volume's change journal. NTFS maintains that journal itself, so
// every create/write/rename on the volume shows up with no setup cost.
//
// This is the same class of mechanism antivirus products use. It is instant to
// start, sees everything on the volume, and holds one handle per drive.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	fsctlQueryUsnJournal = 0x000900f4
	fsctlReadUsnJournal  = 0x000900bb

	usnReasonDataOverwrite = 0x00000001
	usnReasonDataExtend    = 0x00000002
	usnReasonFileCreate    = 0x00000100
	usnReasonRenameNewName = 0x00002000
	usnReasonClose         = 0x80000000
)

type usnJournalData struct {
	UsnJournalID    uint64
	FirstUsn        int64
	NextUsn         int64
	LowestValidUsn  int64
	MaxUsn          int64
	MaximumSize     uint64
	AllocationDelta uint64
}

type readUsnJournalData struct {
	StartUsn          int64
	ReasonMask        uint32
	ReturnOnlyOnClose uint32
	Timeout           uint64
	BytesToWaitFor    uint64
	UsnJournalID      uint64
}

type usnRecordV2 struct {
	RecordLength              uint32
	MajorVersion              uint16
	MinorVersion              uint16
	FileReferenceNumber       uint64
	ParentFileReferenceNumber uint64
	Usn                       int64
	TimeStamp                 int64
	Reason                    uint32
	SourceInfo                uint32
	SecurityID                uint32
	FileAttributes            uint32
	FileNameLength            uint16
	FileNameOffset            uint16
	// FileName follows, FileNameLength bytes of UTF-16
}

type fileIDDescriptor struct {
	DwSize uint32
	Type   uint32
	_      uint32 // padding so FileID lands on an 8-byte boundary
	FileID uint64
	_      uint64 // rest of the GUID union
}

var (
	modkernel32     = windows.NewLazySystemDLL("kernel32.dll")
	procOpenFileByID = modkernel32.NewProc("OpenFileById")
)

// resolveParentPath turns a parent file reference number into a real path by
// opening it by ID and asking Windows for the final path.
func resolveParentPath(volHandle windows.Handle, parentRef uint64) (string, error) {
	desc := fileIDDescriptor{
		DwSize: uint32(unsafe.Sizeof(fileIDDescriptor{})),
		Type:   0, // FileIdType
		FileID: parentRef,
	}

	r, _, err := procOpenFileByID.Call(
		uintptr(volHandle),
		uintptr(unsafe.Pointer(&desc)),
		uintptr(windows.FILE_READ_ATTRIBUTES),
		uintptr(windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE),
		0,
		uintptr(windows.FILE_FLAG_BACKUP_SEMANTICS),
	)
	h := windows.Handle(r)
	if h == windows.InvalidHandle {
		return "", err
	}
	defer windows.CloseHandle(h)

	buf := make([]uint16, windows.MAX_LONG_PATH)
	n, err := windows.GetFinalPathNameByHandle(h, &buf[0], uint32(len(buf)), 0)
	if err != nil || n == 0 {
		return "", err
	}

	p := windows.UTF16ToString(buf[:n])
	p = strings.TrimPrefix(p, `\\?\`)
	return p, nil
}

// watchVolumeUSN follows one volume's change journal until stop is closed.
func (w *watcher) watchVolumeUSN(drive string, stop <-chan struct{}) {
	volPath := `\\.\` + strings.TrimSuffix(drive, `\`) // e.g. \\.\C:

	pathPtr, err := syscall.UTF16PtrFromString(volPath)
	if err != nil {
		w.log("USN %s: bad path: %v", drive, err)
		return
	}

	h, err := windows.CreateFile(
		pathPtr,
		windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		0,
		0,
	)
	if err != nil {
		w.log("USN %s: cannot open volume (%v) - skipping", drive, err)
		return
	}
	defer windows.CloseHandle(h)

	// Ask the volume where its journal currently stands
	var jd usnJournalData
	var bytesReturned uint32

	err = windows.DeviceIoControl(
		h, fsctlQueryUsnJournal,
		nil, 0,
		(*byte)(unsafe.Pointer(&jd)), uint32(unsafe.Sizeof(jd)),
		&bytesReturned, nil,
	)
	if err != nil {
		w.log("USN %s: no change journal on this volume (%v) - skipping", drive, err)
		return
	}

	w.log("USN %s: journal attached (id %d), watching from now on", drive, jd.UsnJournalID)

	// Start from "now" so we do not replay the entire history
	next := jd.NextUsn
	buf := make([]byte, 64*1024)

	for {
		select {
		case <-stop:
			return
		default:
		}

		req := readUsnJournalData{
			StartUsn: next,

			// usnReasonClose MUST be in the mask when ReturnOnlyOnClose is set.
			// With ReturnOnlyOnClose the journal only hands back records that
			// carry USN_REASON_CLOSE; if that bit is missing from the mask the
			// filter can never match and the read returns nothing - forever.
			// That bug made live monitoring silently dead: the service reported
			// "coverage is live" while only the startup sweep ever found
			// anything.
			ReasonMask: usnReasonDataOverwrite | usnReasonDataExtend |
				usnReasonFileCreate | usnReasonRenameNewName | usnReasonClose,

			ReturnOnlyOnClose: 1, // wait for the writer to finish, not mid-write
			Timeout:           1, // seconds to block waiting for data
			BytesToWaitFor:    1, // block until at least 1 byte is available
			UsnJournalID:      jd.UsnJournalID,
		}

		var got uint32
		err := windows.DeviceIoControl(
			h, fsctlReadUsnJournal,
			(*byte)(unsafe.Pointer(&req)), uint32(unsafe.Sizeof(req)),
			&buf[0], uint32(len(buf)),
			&got, nil,
		)
		if err != nil {
			// Timeouts are normal when nothing is happening
			time.Sleep(500 * time.Millisecond)
			continue
		}
		if got < 8 {
			continue
		}

		// First 8 bytes are the USN to resume from next time
		next = *(*int64)(unsafe.Pointer(&buf[0]))

		offset := uint32(8)
		for offset < got {
			rec := (*usnRecordV2)(unsafe.Pointer(&buf[offset]))
			if rec.RecordLength == 0 || offset+rec.RecordLength > got {
				break
			}

			// Directories are not interesting - only files carry the payload
			if rec.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
				nameBytes := buf[offset+uint32(rec.FileNameOffset) : offset+uint32(rec.FileNameOffset)+uint32(rec.FileNameLength)]
				nameU16 := (*[1 << 16]uint16)(unsafe.Pointer(&nameBytes[0]))[: rec.FileNameLength/2 : rec.FileNameLength/2]
				name := string(windows.UTF16ToString(nameU16))

				if w.interestingName(name) {
					// Only now do the (relatively costly) path lookup
					if parent, err := resolveParentPath(h, rec.ParentFileReferenceNumber); err == nil {
						full := filepath.Join(parent, name)
						w.considerUSN(full)
					}
				}
			}

			offset += rec.RecordLength
		}
	}
}

// interestingName is a cheap first filter on the journal record's filename, so
// we do not resolve full paths for every file the machine touches. The
// authoritative check is w.eligible(), applied in handle().
func (w *watcher) interestingName(name string) bool {
	return executableExts[strings.ToLower(filepath.Ext(name))]
}

// considerUSN applies the shared eligibility gate, then scans.
func (w *watcher) considerUSN(path string) {
	if !w.eligible(path) {
		return
	}

	info, err := os.Stat(path)
	if err != nil || info.IsDir() || info.Size() > 20*1024*1024 {
		return
	}

	// Debounce - one save can produce several journal records.
	// Guarded by a mutex because each volume runs in its own goroutine.
	w.seenMu.Lock()
	if last, ok := w.seen[path]; ok && time.Since(last) < 3*time.Second {
		w.seenMu.Unlock()
		return
	}
	w.seen[path] = time.Now()

	// Keep the map from growing without bound. On a whole-PC watch this
	// otherwise accumulates every path the machine ever touches.
	if len(w.seen) > 5000 {
		cutoff := time.Now().Add(-30 * time.Second)
		for k, v := range w.seen {
			if v.Before(cutoff) {
				delete(w.seen, k)
			}
		}
		// Still too big? Drop it entirely - worst case we scan a file twice.
		if len(w.seen) > 20000 {
			w.seen = make(map[string]time.Time, 1024)
		}
	}
	w.seenMu.Unlock()

	w.handle(path, info)
}

// runUSN watches every NTFS volume via its change journal.
// Returns false if no volume could be watched, so the caller can fall back.
func (w *watcher) runUSN(roots []string, stop <-chan struct{}) bool {
	w.log("=== Watcher started - USN journal mode (quarantine: %v) ===", w.quarantine)

	started := 0
	for _, r := range roots {
		// Only drive roots like "C:\" make sense here
		if len(r) < 2 || r[1] != ':' {
			continue
		}
		drive := r[:2] // "C:"

		// Confirm the volume has a journal before committing to it
		pathPtr, err := syscall.UTF16PtrFromString(`\\.\` + drive)
		if err != nil {
			continue
		}
		h, err := windows.CreateFile(pathPtr, windows.GENERIC_READ,
			windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil,
			windows.OPEN_EXISTING, 0, 0)
		if err != nil {
			continue
		}
		var jd usnJournalData
		var n uint32
		err = windows.DeviceIoControl(h, fsctlQueryUsnJournal, nil, 0,
			(*byte)(unsafe.Pointer(&jd)), uint32(unsafe.Sizeof(jd)), &n, nil)
		windows.CloseHandle(h)
		if err != nil {
			w.log("USN %s: no journal (not NTFS?) - skipping", drive)
			continue
		}

		go w.watchVolumeUSN(drive, stop)
		started++
	}

	if started == 0 {
		w.log("USN: no usable volumes found")
		return false
	}

	w.log("USN: watching %d volume(s) - live monitoring active", started)

	// One background sweep so anything already infected is found too.
	go func() {
		w.log("initial full sweep started (live monitoring is already running)")
		for _, r := range roots {
			select {
			case <-stop:
				return
			default:
			}
			w.root = r
			w.sweep(time.Time{})
		}
		w.log("initial full sweep finished")
	}()

	<-stop
	w.log("=== Watcher stopped ===")
	return true
}

func init() {
	// Make the USN path the default on Windows; runEvents falls back to
	// fsnotify if this returns false.
	usnAvailable = func(w *watcher, roots []string, stop <-chan struct{}) bool {
		return w.runUSN(roots, stop)
	}
}

var _ = fmt.Sprintf // keep fmt imported if unused above
