// Moonlight Bureau: Tailscale inside the app, without the Tailscale app and without an iOS VPN.
//
// tsnet runs a Tailscale node in the app process (userspace WireGuard and network stack). The
// bridge listens on 127.0.0.1 for the Sunshine ports (default base 47989 and the 48989 base of a
// second instance), TCP and UDP, and relays everything to the PC over the tailnet. Moonlight
// then connects to 127.0.0.1. The PC is found by itself: the online computer of the account
// that answers on a Sunshine port (a preferred name, if given, is tried first).
//
// Built as a C archive for iOS (go build -buildmode=c-archive), called from Objective-C.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

var (
	mu         sync.Mutex
	started    bool
	server     *tsnet.Server
	state      = "Démarrage"
	authURL    string
	selfIP     string
	targetIP   string
	targetName string
	preferred  string
	account    string
	forwarding bool
	loggedOut  bool
	lastError  string
	logLines   []string
)

func addLog(line string) {
	mu.Lock()
	defer mu.Unlock()
	logLines = append(logLines, time.Now().Format("15:04:05 ")+line)
	if len(logLines) > 40 {
		logLines = logLines[len(logLines)-40:]
	}
}

func setError(err error) {
	mu.Lock()
	lastError = err.Error()
	mu.Unlock()
	addLog("erreur : " + err.Error())
}

// MBTailscaleStart starts the node (once). dir: state folder (keeps the login), hostname: name
// of this device in Tailscale, peer: name of the PC in Tailscale, ports: range to relay.
//
//export MBTailscaleStart
func MBTailscaleStart(dir, hostname, peer *C.char, portStart, portEnd C.int) {
	mu.Lock()
	if started {
		mu.Unlock()
		return
	}
	started = true
	preferred = C.GoString(peer)
	mu.Unlock()
	go run(C.GoString(dir), C.GoString(hostname), int(portStart), int(portEnd))
}

// MBTailscaleStatus returns the state as JSON. The caller frees the string with free().
//
//export MBTailscaleStatus
func MBTailscaleStatus() *C.char {
	mu.Lock()
	defer mu.Unlock()
	out, _ := json.Marshal(map[string]any{
		"state":      state,
		"authURL":    authURL,
		"selfIP":     selfIP,
		"target":     targetIP,
		"targetName": targetName,
		"account":    account,
		"forwarding": forwarding,
		"error":      lastError,
		"log":        logLines,
	})
	return C.CString(string(out))
}

// MBTailscaleLogout signs this device out of Tailscale (the relay stops reaching the PC).
// Blocks up to 10 s; call it off the main thread.
//
//export MBTailscaleLogout
func MBTailscaleLogout() {
	mu.Lock()
	s := server
	mu.Unlock()
	if s == nil {
		return
	}
	lc, err := s.LocalClient()
	if err != nil {
		setError(err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := lc.Logout(ctx); err != nil {
		setError(err)
		return
	}
	mu.Lock()
	loggedOut = true
	forwarding = false
	targetIP, targetName, account, authURL = "", "", "", ""
	state = "NeedsLogin"
	mu.Unlock()
	addLog("déconnecté de Tailscale")
}

// MBTailscaleLogin asks Tailscale for a fresh login link and returns it (empty when already
// connected). A link is tied to its login attempt: after a failed attempt (wrong account), the
// old link keeps showing the same error page. First a new interactive login (4 s to give a
// new link); if the link does not change, the pending attempt is dropped (logout of a node
// that is not logged in) and a clean one is started. Blocks up to ~12 s; call it off the main
// thread. The caller frees the string with free().
//
//export MBTailscaleLogin
func MBTailscaleLogin() *C.char {
	mu.Lock()
	s := server
	old := authURL
	mu.Unlock()
	if s == nil {
		return C.CString(old)
	}
	lc, err := s.LocalClient()
	if err != nil {
		setError(err)
		return C.CString(old)
	}
	wait := func(d time.Duration, differentFrom string) (string, bool) {
		ctx, cancel := context.WithTimeout(context.Background(), d)
		defer cancel()
		for ctx.Err() == nil {
			st, err := lc.StatusWithoutPeers(ctx)
			if err == nil {
				if st.BackendState == "Running" {
					return "", true
				}
				if st.AuthURL != "" && st.AuthURL != differentFrom {
					return st.AuthURL, true
				}
			}
			time.Sleep(200 * time.Millisecond)
		}
		return "", false
	}
	start := func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := lc.StartLoginInteractive(ctx); err != nil {
			addLog("connexion : " + err.Error())
		}
	}

	start()
	url, ok := wait(4*time.Second, old)
	if !ok {
		addLog("lien inchangé : nouvelle tentative de connexion")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		if err := lc.Logout(ctx); err != nil {
			addLog("abandon de la tentative : " + err.Error())
		}
		cancel()
		start()
		url, ok = wait(8*time.Second, "")
	}
	if !ok {
		return C.CString(old)
	}
	if url != "" {
		mu.Lock()
		authURL = url
		mu.Unlock()
		addLog("nouveau lien de connexion")
	}
	return C.CString(url)
}

// Sunshine ports relayed, for both bases: HTTPS, PC clipboard helper, HTTP, video, control,
// audio, mic, RTSP (offsets -5, -2, 0, +9, +10, +11, +13, +21 from the HTTP port).
var relayPorts = func() []int {
	var ports []int
	for _, base := range []int{47989, 48989} {
		for _, off := range []int{-5, -2, 0, 9, 10, 11, 13, 21} {
			ports = append(ports, base+off)
		}
	}
	return ports
}()

func run(dir string, hostname string, _ int, _ int) {
	// No log upload to Tailscale's servers
	os.Setenv("TS_NO_LOGS_NO_SUPPORT", "true")
	// iOS allows 256 open files by default; the relay and Tailscale need more
	var lim syscall.Rlimit
	if syscall.Getrlimit(syscall.RLIMIT_NOFILE, &lim) == nil && lim.Cur < 4096 {
		lim.Cur = 4096
		if lim.Max < lim.Cur {
			lim.Cur = lim.Max
		}
		syscall.Setrlimit(syscall.RLIMIT_NOFILE, &lim)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		setError(err)
		return
	}
	s := &tsnet.Server{
		Dir:      dir,
		Hostname: hostname,
		Logf:     func(string, ...any) {}, // tsnet is very talkative; our own log is enough
		UserLogf: func(format string, args ...any) { addLog(fmt.Sprintf(format, args...)) },
	}
	mu.Lock()
	server = s
	mu.Unlock()
	if err := s.Start(); err != nil {
		setError(err)
		return
	}
	lc, err := s.LocalClient()
	if err != nil {
		setError(err)
		return
	}
	addLog("nœud Tailscale démarré")

	// Local ports open at once: a request made while Tailscale is still starting waits for the
	// PC (waitTarget) instead of failing, so the app finds the PC as soon as the tailnet is up
	if err := startForwarders(s, relayPorts); err != nil {
		setError(err)
	}
	// Last PC found: taken again at once if it is online, without probing its ports
	cacheFile := filepath.Join(dir, "pc-cible")
	cached := ""
	if b, err := os.ReadFile(cacheFile); err == nil {
		cached = strings.TrimSpace(string(b))
	}

	var lastProbe time.Time
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		st, err := lc.Status(ctx)
		cancel()
		if err != nil {
			setError(err)
			time.Sleep(2 * time.Second)
			continue
		}
		mu.Lock()
		state = st.BackendState
		authURL = st.AuthURL
		if st.BackendState == "Running" {
			loggedOut = false
		}
		if st.Self != nil && len(st.Self.TailscaleIPs) > 0 {
			selfIP = st.Self.TailscaleIPs[0].String()
		}
		account = ""
		if st.Self != nil {
			if u, ok := st.User[st.Self.UserID]; ok {
				account = u.LoginName
			}
		}
		current := targetIP
		mu.Unlock()

		if st.BackendState == "Running" {
			if current == "" && cached != "" {
				if name, online := peerInfo(st, cached); online {
					mu.Lock()
					targetIP, targetName = cached, name
					lastError = ""
					mu.Unlock()
					current = cached
					addLog("PC retrouvé : " + name)
				}
			}
			// Keep the current PC while it is online; otherwise look again (every 15 s)
			if current == "" || !peerOnline(st, current) {
				if time.Since(lastProbe) > 15*time.Second || current != "" {
					lastProbe = time.Now()
					ip, name := findTarget(s, st)
					mu.Lock()
					targetIP, targetName = ip, name
					if ip == "" {
						lastError = "Aucun PC trouvé"
					} else {
						lastError = ""
					}
					mu.Unlock()
					if ip != "" {
						addLog("PC trouvé : " + name)
						cached = ip
						os.WriteFile(cacheFile, []byte(ip), 0o600)
					}
				}
			}
		}

		mu.Lock()
		ready := st.BackendState == "Running" && targetIP != ""
		if ready && !forwarding {
			addLog("relais actif")
		}
		forwarding = ready
		mu.Unlock()

		// Fast while starting, then every 2 s
		if ready {
			time.Sleep(2 * time.Second)
		} else {
			time.Sleep(300 * time.Millisecond)
		}
	}
}

func peerInfo(st *ipnstate.Status, ip string) (string, bool) {
	for _, p := range st.Peer {
		for _, a := range p.TailscaleIPs {
			if a.String() == ip {
				return p.HostName, p.Online
			}
		}
	}
	return "", false
}

// The PC address for a port, waiting up to 12 s while Tailscale starts (not when it needs a
// login: then it fails at once)
func waitTarget(port int) (string, bool) {
	deadline := time.Now().Add(12 * time.Second)
	for {
		mu.Lock()
		ip, st, out := targetIP, state, loggedOut
		mu.Unlock()
		if ip != "" {
			return net.JoinHostPort(ip, strconv.Itoa(port)), true
		}
		if st == "NeedsLogin" || out || time.Now().After(deadline) {
			return "", false
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func peerOnline(st *ipnstate.Status, ip string) bool {
	for _, p := range st.Peer {
		for _, a := range p.TailscaleIPs {
			if a.String() == ip {
				return p.Online
			}
		}
	}
	return false
}

// The PC: preferred name first if given, then any online computer (not a phone or tablet) of
// the account that answers on a Sunshine HTTP port.
func findTarget(s *tsnet.Server, st *ipnstate.Status) (string, string) {
	type cand struct{ ip, name string }
	var first, rest []cand
	for _, p := range st.Peer {
		if !p.Online {
			continue
		}
		osName := strings.ToLower(p.OS)
		if osName == "ios" || osName == "android" {
			continue
		}
		ip := ""
		for _, a := range p.TailscaleIPs {
			if a.Is4() {
				ip = a.String()
			}
		}
		if ip == "" {
			continue
		}
		c := cand{ip, p.HostName}
		mu.Lock()
		pref := strings.ToLower(preferred)
		mu.Unlock()
		if pref != "" && strings.ToLower(p.HostName) == pref {
			first = append(first, c)
		} else {
			rest = append(rest, c)
		}
	}
	for _, c := range append(first, rest...) {
		for _, port := range []int{48989, 47989} {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			conn, err := s.Dial(ctx, "tcp", net.JoinHostPort(c.ip, strconv.Itoa(port)))
			cancel()
			if err == nil {
				conn.Close()
				return c.ip, c.name
			}
		}
	}
	return "", ""
}

func currentTarget(port int) string {
	mu.Lock()
	defer mu.Unlock()
	return net.JoinHostPort(targetIP, strconv.Itoa(port))
}

func startForwarders(s *tsnet.Server, ports []int) error {
	for _, port := range ports {
		ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
		if err != nil {
			return fmt.Errorf("port TCP %d : %w", port, err)
		}
		go serveTCP(s, ln, port)
		pc, err := net.ListenPacket("udp", "127.0.0.1:"+strconv.Itoa(port))
		if err != nil {
			return fmt.Errorf("port UDP %d : %w", port, err)
		}
		go serveUDP(s, pc, port)
	}
	return nil
}

func serveTCP(s *tsnet.Server, ln net.Listener, port int) {
	for {
		c, err := ln.Accept()
		if err != nil {
			setError(err)
			time.Sleep(time.Second)
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			target, ok := waitTarget(port)
			if !ok {
				return
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			rc, err := s.Dial(ctx, "tcp", target)
			cancel()
			if err != nil {
				addLog(fmt.Sprintf("TCP %d : %v", port, err))
				return
			}
			defer rc.Close()
			done := make(chan struct{}, 2)
			go func() { io.Copy(rc, c); closeWrite(rc); done <- struct{}{} }()
			go func() { io.Copy(c, rc); closeWrite(c); done <- struct{}{} }()
			<-done
			<-done
		}(c)
	}
}

func closeWrite(c net.Conn) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		cw.CloseWrite()
	}
}

// UDP: one tailnet "connection" per local client address (video, audio, control each use
// their own socket), like a small NAT. Idle sessions close after 60 s.
func serveUDP(s *tsnet.Server, pc net.PacketConn, port int) {
	var smu sync.Mutex
	sessions := map[string]net.Conn{}
	buf := make([]byte, 65535)
	for {
		n, addr, err := pc.ReadFrom(buf)
		if err != nil {
			setError(err)
			time.Sleep(time.Second)
			continue
		}
		key := addr.String()
		smu.Lock()
		rc := sessions[key]
		smu.Unlock()
		if rc == nil {
			mu.Lock()
			noTarget := targetIP == ""
			mu.Unlock()
			if noTarget {
				continue // not ready yet: Moonlight sends again
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			rc, err = s.Dial(ctx, "udp", currentTarget(port))
			cancel()
			if err != nil {
				addLog(fmt.Sprintf("UDP %d : %v", port, err))
				continue
			}
			smu.Lock()
			sessions[key] = rc
			smu.Unlock()
			go func(rc net.Conn, addr net.Addr, key string) {
				defer func() {
					rc.Close()
					smu.Lock()
					delete(sessions, key)
					smu.Unlock()
				}()
				b := make([]byte, 65535)
				for {
					rc.SetReadDeadline(time.Now().Add(60 * time.Second))
					m, err := rc.Read(b)
					if err != nil {
						var ne net.Error
						if !(errors.As(err, &ne) && ne.Timeout()) {
							addLog(fmt.Sprintf("UDP %d : %v", port, err))
						}
						return
					}
					pc.WriteTo(b[:m], addr)
				}
			}(rc, addr, key)
		}
		if _, err := rc.Write(buf[:n]); err != nil {
			addLog(fmt.Sprintf("UDP %d envoi : %v", port, err))
		}
	}
}

func main() {}
