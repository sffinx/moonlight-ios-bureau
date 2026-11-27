// Moonlight Bureau: Tailscale inside the app, without the Tailscale app and without an iOS VPN.
//
// tsnet runs a Tailscale node in the app process (userspace WireGuard and network stack). The
// bridge listens on 127.0.0.1 for the ports of the PC's "Sunshine Tel" instance (TCP and UDP)
// and relays everything to the PC over the tailnet. Moonlight then connects to 127.0.0.1.
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
	"strconv"
	"strings"
	"sync"
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
	forwarding bool
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
	targetName = C.GoString(peer)
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
		"forwarding": forwarding,
		"error":      lastError,
		"log":        logLines,
	})
	return C.CString(string(out))
}

func run(dir string, hostname string, portStart, portEnd int) {
	// No log upload to Tailscale's servers
	os.Setenv("TS_NO_LOGS_NO_SUPPORT", "true")
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

	forwardersUp := false
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
		if st.Self != nil && len(st.Self.TailscaleIPs) > 0 {
			selfIP = st.Self.TailscaleIPs[0].String()
		}
		if st.BackendState == "Running" {
			if ip := findPeer(st, targetName); ip != "" {
				if ip != targetIP {
					targetIP = ip
					lastError = ""
				}
			} else {
				lastError = "PC « " + targetName + " » introuvable dans Tailscale"
			}
		}
		ready := st.BackendState == "Running" && targetIP != ""
		mu.Unlock()

		if ready && !forwardersUp {
			if err := startForwarders(s, portStart, portEnd); err != nil {
				setError(err)
			} else {
				forwardersUp = true
				mu.Lock()
				forwarding = true
				mu.Unlock()
				addLog(fmt.Sprintf("relais 127.0.0.1:%d-%d -> %s", portStart, portEnd, targetIP))
			}
		}
		time.Sleep(2 * time.Second)
	}
}

func findPeer(st *ipnstate.Status, name string) string {
	name = strings.ToLower(name)
	for _, p := range st.Peer {
		host := strings.ToLower(p.HostName)
		dns := strings.ToLower(p.DNSName)
		if host == name || strings.HasPrefix(dns, name+".") {
			for _, ip := range p.TailscaleIPs {
				if ip.Is4() {
					return ip.String()
				}
			}
		}
	}
	return ""
}

func currentTarget(port int) string {
	mu.Lock()
	defer mu.Unlock()
	return net.JoinHostPort(targetIP, strconv.Itoa(port))
}

func startForwarders(s *tsnet.Server, portStart, portEnd int) error {
	for port := portStart; port <= portEnd; port++ {
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
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			rc, err := s.Dial(ctx, "tcp", currentTarget(port))
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
