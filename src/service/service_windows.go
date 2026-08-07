//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/eventlog"
	"golang.org/x/sys/windows/svc/mgr"
)

type windowsService struct {
	w     *watcher
	roots []string
}

func (s *windowsService) Execute(args []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	const accepted = svc.AcceptStop | svc.AcceptShutdown

	changes <- svc.Status{State: svc.StartPending}

	stop := make(chan struct{})
	go s.w.runEvents(s.roots, stop)

	changes <- svc.Status{State: svc.Running, Accepts: accepted}

	for c := range r {
		switch c.Cmd {
		case svc.Interrogate:
			changes <- c.CurrentStatus
		case svc.Stop, svc.Shutdown:
			close(stop)
			changes <- svc.Status{State: svc.StopPending}
			return false, 0
		}
	}
	return false, 0
}

// runService is called when the Service Control Manager starts us.
func runService(w *watcher, roots []string) {
	svc.Run(serviceName, &windowsService{w: w, roots: roots})
}

func installService(paths []string, all bool, quarantine bool) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}

	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()

	if s, err := m.OpenService(serviceName); err == nil {
		s.Close()
		return fmt.Errorf("service %s already exists - run 'remove' first", serviceName)
	}

	args := []string{"run"}
	if all {
		args = append(args, "-all")
	} else {
		for _, p := range paths {
			abs, _ := filepath.Abs(p)
			args = append(args, "-path", abs)
		}
	}
	if quarantine {
		args = append(args, "-quarantine")
	}

	s, err := m.CreateService(serviceName, exe, mgr.Config{
		DisplayName: serviceDesc,
		Description: "Detects and removes injected malware in project files in real time.",
		StartType:   mgr.StartAutomatic,
	}, args...)
	if err != nil {
		return err
	}
	defer s.Close()

	s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 10 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
	}, 86400)

	eventlog.InstallAsEventCreate(serviceName, eventlog.Error|eventlog.Warning|eventlog.Info)
	return nil
}

func controlService(cmd string) error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()

	s, err := m.OpenService(serviceName)
	if err != nil {
		return fmt.Errorf("service not installed: %v", err)
	}
	defer s.Close()

	switch cmd {
	case "start":
		return s.Start()
	case "stop":
		_, err := s.Control(svc.Stop)
		return err
	case "remove":
		s.Control(svc.Stop)
		time.Sleep(time.Second)
		eventlog.Remove(serviceName)
		return s.Delete()
	}
	return nil
}

func handleServiceCommand(cmd string, paths []string, all bool, quarantine bool) {
	switch cmd {
	case "install":
		if !all && len(paths) == 0 {
			fmt.Println("give -all (whole machine) or -path <folder>")
			return
		}
		if err := installService(paths, all, quarantine); err != nil {
			fmt.Println("install failed:", err)
			return
		}
		target := "whole machine (all drives)"
		if !all {
			target = fmt.Sprintf("%v", paths)
		}
		fmt.Printf("Service %q installed.\n  Watching: %s\n  Quarantine: %v\n", serviceName, target, quarantine)
		fmt.Println("Start it with:  watcher-service.exe start")

	case "start", "stop", "remove":
		if err := controlService(cmd); err != nil {
			fmt.Printf("%s failed: %v\n", cmd, err)
			return
		}
		fmt.Printf("Service %s: ok\n", cmd)
	}
}
