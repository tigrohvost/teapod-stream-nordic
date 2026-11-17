package main

import (
	"bufio"
	"bytes"
	"context"
	crand "crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	kcp "github.com/xtaci/kcp-go/v5"
	"github.com/xtaci/smux"
)

func smuxConfig() *smux.Config {
	c := smux.DefaultConfig()
	c.Version = 2
	c.KeepAliveInterval = 5 * time.Second
	c.KeepAliveTimeout = 25 * time.Second
	c.MaxReceiveBuffer = 4 * 1024 * 1024
	c.MaxStreamBuffer = 256 * 1024
	c.MaxFrameSize = 16 * 1024
	return c
}

type liveSession struct {
	mux     *mux
	streams *smux.Session
}

func (s *liveSession) Close() { s.streams.Close(); s.mux.Close() }

type clientManager struct {
	mu      sync.Mutex
	dialMu  sync.Mutex
	c       Config
	session *liveSession
	closed  bool
	egress  *egressSelector
}

func (cm *clientManager) get() (*liveSession, error) {
	cm.dialMu.Lock()
	defer cm.dialMu.Unlock()
	cm.mu.Lock()
	if cm.closed {
		cm.mu.Unlock()
		return nil, net.ErrClosed
	}
	if cm.session != nil && !cm.session.streams.IsClosed() {
		s := cm.session
		cm.mu.Unlock()
		return s, nil
	}
	old := cm.session
	cm.session = nil
	cm.mu.Unlock()
	if old != nil {
		old.Close()
	}
	id := make([]byte, 16)
	if _, e := crand.Read(id); e != nil {
		return nil, e
	}
	h := Hello{Token: cm.c.Token, SID: hex.EncodeToString(id), Mode: cm.c.Mode}
	m := newMux(h, true)
	for _, name := range []string{"A", "B"} {
		if (cm.c.Mode == "A" || cm.c.Mode == "B") && cm.c.Mode != name {
			continue
		}
		go func(name string) {
			for {
				select {
				case <-m.done:
					return
				default:
				}
				conn, e := dial(cm.c, name)
				if e == nil {
					conn.SetDeadline(time.Now().Add(10 * time.Second))
					b, _ := json.Marshal(h)
					_, e = conn.Write(append(append(b, '\n'), name[0]))
					if e == nil {
						conn.SetDeadline(time.Time{})
						m.add(name, conn, conn)
						m.mu.Lock()
						p := m.paths[name]
						m.mu.Unlock()
						select {
						case <-p.done:
						case <-m.done:
							return
						}
					} else {
						conn.Close()
					}
				}
				select {
				case <-m.done:
					return
				case <-time.After(time.Second):
				}
			}
		}(name)
	}
	ready := false
	for until := time.Now().Add(12 * time.Second); time.Now().Before(until); {
		m.mu.Lock()
		for _, p := range m.paths {
			if p.ready {
				ready = true
			}
		}
		m.mu.Unlock()
		if ready {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !ready {
		m.Close()
		return nil, errors.New("neither transport is available")
	}
	kc, e := kcp.NewConn2(&net.UDPAddr{IP: net.IPv4(10, 254, 0, 1), Port: 10000}, nil, 0, 0, m)
	if e != nil {
		m.Close()
		return nil, e
	}
	tune(kc)
	ss, e := smux.Client(kc, smuxConfig())
	if e != nil {
		kc.Close()
		m.Close()
		return nil, e
	}
	m.begin()
	cm.mu.Lock()
	defer cm.mu.Unlock()
	if cm.closed {
		ss.Close()
		m.Close()
		return nil, net.ErrClosed
	}
	cm.session = &liveSession{m, ss}
	return cm.session, nil
}
func (cm *clientManager) close() {
	cm.mu.Lock()
	defer cm.mu.Unlock()
	cm.closed = true
	if cm.session != nil {
		cm.session.Close()
	}
}

func bootSeconds() float64 {
	var ts unix.Timespec
	if unix.ClockGettime(unix.CLOCK_BOOTTIME, &ts) != nil {
		return 0
	}
	return float64(ts.Sec) + float64(ts.Nsec)/1e9
}
func atomicStatus(path string, state map[string]any) error {
	b, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if err = os.WriteFile(path+".tmp", b, 0600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}
func (cm *clientManager) status() {
	var lastError time.Time
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		cm.mu.Lock()
		if cm.closed {
			cm.mu.Unlock()
			return
		}
		s := cm.session
		cm.mu.Unlock()
		state := map[string]any{"schema_version": 2, "boot_id": cm.c.BootID,
			"process_generation": os.Getenv("TEAPOD_PROCESS_GENERATION"),
			"runtime_generation": cm.c.RuntimeGeneration, "config_hash": cm.c.ConfigHash,
			"network_epoch": cm.c.NetworkEpoch, "session_id": "pending", "pid": os.Getpid(),
			"observed_boot": bootSeconds(), "state": "unavailable", "mode": cm.c.Mode,
			"ready_A": false, "ready_B": false, "streams": 0, "updated_unix": time.Now().Unix()}
		state["valid_until_boot"] = state["observed_boot"].(float64) + 8
		if s != nil {
			if s.streams.IsClosed() {
				s.mux.Close()
			} else {
				state["streams"] = s.streams.NumStreams()
				state["session_id"] = s.mux.h.SID
				s.mux.mu.Lock()
				for name, p := range s.mux.paths {
					state["ready_"+name] = p.ready && time.Since(p.lastPong) < 3500*time.Millisecond
					state["rtt_ms_"+name] = p.rtt.Milliseconds()
				}
				for k, v := range s.mux.stats {
					state[k] = v
				}
				s.mux.mu.Unlock()
			}
		}
		if cm.c.Status != "" {
			a, b := state["ready_A"].(bool), state["ready_B"].(bool)
			if a && b {
				state["state"] = "ready"
			} else if a || b {
				state["state"] = "degraded"
			}
			if cm.egress != nil {
				selected, verified := cm.egress.current(bootSeconds())
				state["selected_egress"] = selected
				state["egress_verified_boot"] = verified
			}
			if err := atomicStatus(cm.c.Status, state); err != nil && time.Since(lastError) > 30*time.Second {
				emit("status_write_failed", map[string]any{"error": "status unavailable"})
				lastError = time.Now()
			}
		}
	}
}

func readAddress(r io.Reader) (string, []byte, error) {
	first := make([]byte, 1)
	if _, e := io.ReadFull(r, first); e != nil {
		return "", nil, e
	}
	raw := append([]byte{}, first...)
	var host string
	switch first[0] {
	case 1, 4:
		n := 4
		if first[0] == 4 {
			n = 16
		}
		b := make([]byte, n)
		if _, e := io.ReadFull(r, b); e != nil {
			return "", nil, e
		}
		host = net.IP(b).String()
		raw = append(raw, b...)
	case 3:
		b := make([]byte, 1)
		if _, e := io.ReadFull(r, b); e != nil {
			return "", nil, e
		}
		if b[0] == 0 {
			return "", nil, errors.New("empty domain")
		}
		raw = append(raw, b...)
		b = make([]byte, int(b[0]))
		if _, e := io.ReadFull(r, b); e != nil {
			return "", nil, e
		}
		host = string(b)
		raw = append(raw, b...)
	default:
		return "", nil, errors.New("unsupported address type")
	}
	port := make([]byte, 2)
	if _, e := io.ReadFull(r, port); e != nil {
		return "", nil, e
	}
	raw = append(raw, port...)
	return net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(port)))), raw, nil
}
func addressBytes(a *net.UDPAddr) []byte {
	out := []byte{4}
	ip := a.IP.To16()
	if v := a.IP.To4(); v != nil {
		out = []byte{1}
		ip = v
	}
	out = append(out, ip...)
	return binary.BigEndian.AppendUint16(out, uint16(a.Port))
}
func socksReply(w io.Writer, code byte, a *net.UDPAddr) error {
	if a == nil {
		a = &net.UDPAddr{IP: net.IPv4zero, Port: 0}
	}
	_, e := w.Write(append([]byte{5, code, 0}, addressBytes(a)...))
	return e
}

func authenticate(conn net.Conn, c Config) error {
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	b := make([]byte, 2)
	if _, e := io.ReadFull(conn, b); e != nil {
		return e
	}
	if b[0] != 5 || b[1] == 0 {
		return errors.New("invalid SOCKS version")
	}
	methods := make([]byte, int(b[1]))
	if _, e := io.ReadFull(conn, methods); e != nil {
		return e
	}
	method := byte(255)
	for _, m := range methods {
		if m == 2 {
			method = 2
		}
	}
	if _, e := conn.Write([]byte{5, method}); e != nil {
		return e
	}
	if method == 255 {
		return errors.New("SOCKS authentication required")
	}
	if _, e := io.ReadFull(conn, b); e != nil {
		return e
	}
	if b[0] != 1 {
		return errors.New("invalid authentication version")
	}
	user := make([]byte, int(b[1]))
	if _, e := io.ReadFull(conn, user); e != nil {
		return e
	}
	if _, e := io.ReadFull(conn, b[:1]); e != nil {
		return e
	}
	pass := make([]byte, int(b[0]))
	if _, e := io.ReadFull(conn, pass); e != nil {
		return e
	}
	if subtle.ConstantTimeCompare(user, []byte(c.SocksUser)) != 1 || subtle.ConstantTimeCompare(pass, []byte(c.SocksPassword)) != 1 {
		conn.Write([]byte{1, 1})
		return errors.New("authentication failed")
	}
	_, e := conn.Write([]byte{1, 0})
	return e
}

func proxyClient(c Config) error {
	l, e := net.Listen("tcp", c.Listen)
	if e != nil {
		return e
	}
	defer l.Close()
	cm := &clientManager{c: c}
	defer cm.close()
	if c.FallbackProxy != "" {
		if err := validateFallback(c); err != nil {
			return err
		}
		cm.egress = newEgressSelector(cm)
		defer cm.egress.stop()
		cm.egress.start()
	}
	go cm.status()
	go func() {
		for {
			cm.mu.Lock()
			closed := cm.closed
			cm.mu.Unlock()
			if closed {
				return
			}
			cm.get()
			time.Sleep(2 * time.Second)
		}
	}()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	go func() { <-signals; l.Close(); cm.close() }()
	slots := make(chan struct{}, 256)
	emit("listening", map[string]any{"role": "proxy", "mode": c.Mode})
	for {
		conn, e := l.Accept()
		if e != nil {
			return e
		}
		select {
		case slots <- struct{}{}:
		default:
			conn.Close()
			continue
		}
		go func() {
			defer func() { <-slots }()
			defer conn.Close()
			if authenticate(conn, c) != nil {
				return
			}
			b := make([]byte, 3)
			if _, e := io.ReadFull(conn, b); e != nil {
				return
			}
			if b[0] != 5 || b[2] != 0 {
				return
			}
			_, raw, e := readAddress(conn)
			if e != nil {
				socksReply(conn, 8, nil)
				return
			}
			if b[1] != 1 && b[1] != 3 {
				socksReply(conn, 7, nil)
				return
			}
			if cm.egress != nil {
				selected, _ := cm.egress.current(bootSeconds())
				if selected == "fallback" {
					forwardFallback(conn, c, b[1], raw)
					return
				}
				if selected != "primary" {
					socksReply(conn, 1, nil)
					return
				}
			}
			session, e := cm.get()
			if e != nil {
				socksReply(conn, 1, nil)
				return
			}
			stream, e := session.streams.OpenStream()
			if e != nil {
				socksReply(conn, 1, nil)
				return
			}
			defer stream.Close()
			stream.SetDeadline(time.Now().Add(15 * time.Second))
			if _, e = stream.Write(append([]byte{b[1]}, raw...)); e != nil {
				socksReply(conn, 1, nil)
				return
			}
			ack := make([]byte, 1)
			if _, e = io.ReadFull(stream, ack); e != nil || ack[0] != 0 {
				socksReply(conn, 5, nil)
				return
			}
			stream.SetDeadline(time.Time{})
			conn.SetDeadline(time.Time{})
			if b[1] == 3 {
				udpClient(conn, stream)
				return
			}
			if socksReply(conn, 0, nil) != nil {
				return
			}
			bridge(conn, stream)
		}()
	}
}

// End-of-write is an ordered application record. Keep smux open until both
// directions consume FIN, so transport-level close cannot recycle unread data.
func bridge(conn net.Conn, stream *smux.Stream) {
	done := make(chan error, 2)
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				if e := frame(stream, 0, buf[:n]); e != nil {
					done <- e
					return
				}
			}
			if err != nil {
				if errors.Is(err, io.EOF) {
					done <- frame(stream, 1, nil)
				} else {
					done <- err
				}
				return
			}
		}
	}()
	go func() {
		for {
			kind, data, err := readFrame(stream)
			if err != nil {
				done <- err
				return
			}
			switch kind {
			case 0:
				if _, err = conn.Write(data); err != nil {
					done <- err
					return
				}
			case 1:
				if len(data) != 0 {
					done <- errors.New("invalid FIN")
					return
				}
				if t, ok := conn.(interface{ CloseWrite() error }); ok {
					done <- t.CloseWrite()
				} else {
					done <- nil
				}
				return
			default:
				done <- errors.New("invalid stream record")
				return
			}
		}
	}()
	if e := <-done; e != nil {
		conn.Close()
		stream.Close()
	}
	<-done
}

func udpClient(control net.Conn, stream *smux.Stream) {
	udp, e := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if e != nil {
		socksReply(control, 1, nil)
		return
	}
	defer udp.Close()
	if socksReply(control, 0, udp.LocalAddr().(*net.UDPAddr)) != nil {
		return
	}
	done := make(chan struct{}, 3)
	var peerMu sync.Mutex
	var peer *net.UDPAddr
	go func() {
		defer func() { done <- struct{}{} }()
		buf := make([]byte, 65535)
		for {
			n, src, e := udp.ReadFromUDP(buf)
			if e != nil {
				return
			}
			if !src.IP.IsLoopback() || n < 4 || buf[0] != 0 || buf[1] != 0 || buf[2] != 0 {
				continue
			}
			peerMu.Lock()
			if peer == nil {
				peer = src
			}
			same := src.String() == peer.String()
			peerMu.Unlock()
			if !same {
				continue
			}
			if frame(stream, 0, buf[3:n]) != nil {
				return
			}
		}
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		for {
			k, b, e := readFrame(stream)
			if e != nil || k != 0 {
				return
			}
			peerMu.Lock()
			p := peer
			peerMu.Unlock()
			if p != nil {
				udp.WriteToUDP(append([]byte{0, 0, 0}, b...), p)
			}
		}
	}()
	go func() { io.Copy(io.Discard, control); done <- struct{}{} }()
	<-done
	udp.Close()
	stream.Close()
	control.Close()
	<-done
	<-done
}

func publicIP(ip net.IP) bool {
	return ip.IsGlobalUnicast() && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() && !ip.IsUnspecified()
}
func resolveTarget(ctx context.Context, target string, allowPrivate bool) (*net.UDPAddr, error) {
	host, port, e := net.SplitHostPort(target)
	if e != nil {
		return nil, e
	}
	p, e := strconv.Atoi(port)
	if e != nil || p < 1 || p > 65535 {
		return nil, errors.New("invalid port")
	}
	ips, e := net.DefaultResolver.LookupIPAddr(ctx, host)
	if e != nil {
		return nil, e
	}
	for _, v := range ips {
		if allowPrivate || publicIP(v.IP) {
			return &net.UDPAddr{IP: v.IP, Port: p}, nil
		}
	}
	return nil, errors.New("destination not permitted")
}
func udpServer(stream *smux.Stream, c Config) {
	udp, e := net.ListenUDP("udp", nil)
	if e != nil {
		stream.Write([]byte{1})
		return
	}
	defer udp.Close()
	if _, e = stream.Write([]byte{0}); e != nil {
		return
	}
	stream.SetDeadline(time.Time{})
	done := make(chan struct{}, 2)
	var mu sync.Mutex
	allowed := map[string]time.Time{}
	go func() {
		defer func() { done <- struct{}{} }()
		for {
			k, b, e := readFrame(stream)
			if e != nil || k != 0 {
				return
			}
			r := bufio.NewReaderSize(bytes.NewReader(b), 65536)
			target, raw, e := readAddress(r)
			if e != nil {
				continue
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			dest, e := resolveTarget(ctx, target, c.AllowPrivate)
			cancel()
			if e != nil {
				continue
			}
			mu.Lock()
			now := time.Now()
			for key, t := range allowed {
				if now.Sub(t) > 2*time.Minute {
					delete(allowed, key)
				}
			}
			if len(allowed) >= 256 {
				mu.Unlock()
				continue
			}
			allowed[dest.String()] = now
			mu.Unlock()
			udp.SetReadDeadline(time.Now().Add(2 * time.Minute))
			udp.WriteToUDP(b[len(raw):], dest)
		}
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		buf := make([]byte, 65507)
		for {
			udp.SetReadDeadline(time.Now().Add(2 * time.Minute))
			n, src, e := udp.ReadFromUDP(buf)
			if e != nil {
				return
			}
			mu.Lock()
			_, ok := allowed[src.String()]
			mu.Unlock()
			if !ok {
				continue
			}
			if frame(stream, 0, append(addressBytes(src), buf[:n]...)) != nil {
				return
			}
		}
	}()
	<-done
	udp.Close()
	stream.Close()
	<-done
}

func serveStream(stream *smux.Stream, c Config) {
	defer stream.Close()
	stream.SetDeadline(time.Now().Add(15 * time.Second))
	cmd := make([]byte, 1)
	if _, e := io.ReadFull(stream, cmd); e != nil {
		return
	}
	target, _, e := readAddress(stream)
	if e != nil {
		return
	}
	if cmd[0] == 3 {
		udpServer(stream, c)
		return
	}
	if cmd[0] != 1 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	addr, e := resolveTarget(ctx, target, c.AllowPrivate)
	if e != nil {
		stream.Write([]byte{2})
		return
	}
	conn, e := (&net.Dialer{}).DialContext(ctx, "tcp", addr.String())
	if e != nil {
		stream.Write([]byte{5})
		return
	}
	defer conn.Close()
	if _, e = stream.Write([]byte{0}); e != nil {
		return
	}
	stream.SetDeadline(time.Time{})
	bridge(conn, stream)
}

func proxyServer(c Config) error {
	listener := tlsServer(c)
	defer listener.Close()
	var mu sync.Mutex
	type session struct {
		m        *mux
		listener *kcp.Listener
		closed   chan struct{}
	}
	sessions := map[string]*session{}
	handshakes := make(chan struct{}, 64)
	for {
		conn, e := listener.Accept()
		if e != nil {
			return e
		}
		select {
		case handshakes <- struct{}{}:
		default:
			conn.Close()
			continue
		}
		go func(t net.Conn) {
			defer func() { <-handshakes }()
			t.SetDeadline(time.Now().Add(10 * time.Second))
			r := bufio.NewReaderSize(t, 4096)
			h, e := hello(r, c.Token)
			if e != nil {
				t.Close()
				return
			}
			if h.Mode != "adaptive" && h.Mode != "standby" && h.Mode != "split" && h.Mode != "A" && h.Mode != "B" {
				t.Close()
				return
			}
			name, e := r.ReadByte()
			if e != nil || (name != 'A' && name != 'B') {
				t.Close()
				return
			}
			h.Scenario = ""
			h.FaultStartMs = 0
			h.FaultDurationMs = 0
			mu.Lock()
			s := sessions[h.SID]
			if s != nil && s.m.h.Mode != h.Mode {
				mu.Unlock()
				t.Close()
				return
			}
			if s == nil {
				if len(sessions) >= c.MaxSessions {
					mu.Unlock()
					t.Close()
					return
				}
				m := newMux(h, false)
				kl, e := kcp.ServeConn(nil, 0, 0, m)
				if e != nil {
					mu.Unlock()
					m.Close()
					t.Close()
					return
				}
				s = &session{m, kl, make(chan struct{})}
				sessions[h.SID] = s
				go func(s *session) {
					defer func() {
						s.listener.Close()
						s.m.Close()
						close(s.closed)
						mu.Lock()
						if sessions[h.SID] == s {
							delete(sessions, h.SID)
						}
						mu.Unlock()
					}()
					s.listener.SetDeadline(time.Now().Add(15 * time.Second))
					kc, e := s.listener.AcceptKCP()
					if e != nil {
						return
					}
					defer kc.Close()
					tune(kc)
					ss, e := smux.Server(kc, smuxConfig())
					if e != nil {
						return
					}
					defer ss.Close()
					slots := make(chan struct{}, 256)
					emit("session_open", map[string]any{"sid": h.SID, "mode": h.Mode})
					for {
						st, e := ss.AcceptStream()
						if e != nil {
							return
						}
						select {
						case slots <- struct{}{}:
							go func() { defer func() { <-slots }(); serveStream(st, c) }()
						default:
							st.Close()
						}
					}
				}(s)
			}
			mu.Unlock()
			t.SetDeadline(time.Time{})
			s.m.add(string(name), t, r)
		}(conn)
	}
}

func main() {
	config := flag.String("config", "", "private configuration file")
	flag.Parse()
	b, e := os.ReadFile(*config)
	must(e)
	var c Config
	must(json.Unmarshal(b, &c))
	sum := sha256.Sum256(b)
	c.ConfigHash = hex.EncodeToString(sum[:])
	if c.RuntimeGeneration == "" {
		var id [16]byte
		_, err := crand.Read(id[:])
		must(err)
		c.RuntimeGeneration = hex.EncodeToString(id[:])
	}
	if c.BootID == "" {
		id, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
		must(err)
		c.BootID = strings.TrimSpace(string(id))
	}
	if c.NetworkEpoch == "" {
		c.NetworkEpoch = c.RuntimeGeneration
	}
	if len(c.Token) < 32 {
		must(errors.New("token must contain at least 32 characters"))
	}
	if c.Mode == "" {
		c.Mode = "adaptive"
	}
	if c.MaxSessions == 0 {
		c.MaxSessions = 16
	}
	switch c.Role {
	case "proxy":
		parent := os.Getppid()
		go func() {
			for range time.NewTicker(2 * time.Second).C {
				if os.Getppid() != parent {
					os.Exit(0)
				}
			}
		}()
		host, _, e := net.SplitHostPort(c.Listen)
		must(e)
		ip := net.ParseIP(host)
		if ip == nil || !ip.IsLoopback() {
			must(errors.New("client listener must be loopback"))
		}
		if c.SocksUser == "" || len(c.SocksPassword) < 16 {
			must(errors.New("local SOCKS credentials required"))
		}
		roots(c)
		e = proxyClient(c)
	case "server":
		e = proxyServer(c)
	default:
		e = fmt.Errorf("unknown role %q", c.Role)
	}
	if e != nil && !errors.Is(e, net.ErrClosed) {
		must(e)
	}
}
