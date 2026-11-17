package main

// The independent exit is selected for NEW SOCKS associations. Existing streams
// retain their exit; an exit change cannot preserve remote TCP sessions.
import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type exitHealth struct {
	good, bad int
	healthy   bool
	verified  float64
}
type exitSample struct {
	name      string
	ok, wrong bool
	at        float64
}
type egressSelector struct {
	mu          sync.Mutex
	cm          *clientManager
	health      map[string]*exitHealth
	selected    string
	selectedAt  float64
	done        chan struct{}
	samples     chan exitSample
	unavailable func() bool
}

func validateFallback(c Config) error {
	host, port, err := net.SplitHostPort(c.FallbackProxy)
	n, _ := strconv.Atoi(port)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() || n < 1 || n > 65535 {
		return errors.New("fallback must be an authenticated loopback SOCKS proxy")
	}
	for _, ips := range [][]string{c.PrimaryIPs, c.FallbackIPs} {
		if len(ips) == 0 {
			return errors.New("each exit requires verified IPs")
		}
		for _, ip := range ips {
			if net.ParseIP(ip) == nil {
				return errors.New("invalid expected exit IP")
			}
		}
	}
	for _, a := range c.PrimaryIPs {
		for _, b := range c.FallbackIPs {
			if net.ParseIP(a).Equal(net.ParseIP(b)) {
				return errors.New("fallback exit is not independent")
			}
		}
	}
	if c.ProxyUser == "" || c.ProxyPassword == "" {
		return errors.New("fallback credentials required")
	}
	return nil
}
func newEgressSelector(cm *clientManager) *egressSelector {
	return &egressSelector{cm: cm, health: map[string]*exitHealth{"primary": {}, "fallback": {}},
		selected: "block", done: make(chan struct{}), samples: make(chan exitSample, 2), unavailable: cm.transportsUnavailable}
}
func (e *egressSelector) stop() { close(e.done) }
func (e *egressSelector) current(now float64) (string, float64) {
	e.mu.Lock()
	defer e.mu.Unlock()
	h := e.health[e.selected]
	if h == nil || !h.healthy || now < h.verified || now-h.verified > 35 {
		return "block", 0
	}
	return e.selected, h.verified
}
func (e *egressSelector) ingest(s exitSample) {
	e.mu.Lock()
	defer e.mu.Unlock()
	h := e.health[s.name]
	if s.ok {
		h.good++
		h.bad = 0
		h.verified = s.at
		if h.good >= 3 {
			h.healthy = true
		}
	} else {
		h.good = 0
		h.bad++
		if h.bad >= 3 || s.wrong {
			h.healthy = false
		}
		// Two independent end-to-end failures plus loss of BOTH transports
		// provide a faster signal; one unavailable leg never triggers this.
		if s.name == "primary" && h.bad >= 2 && e.unavailable() {
			h.healthy = false
		}
	}
	usable := func(name string) bool {
		v := e.health[name]
		return v != nil && v.healthy && s.at-v.verified <= 35 && s.at >= v.verified
	}
	next := e.selected
	if !usable(next) {
		next = "block"
		for _, name := range []string{"primary", "fallback"} {
			if usable(name) {
				next = name
				break
			}
		}
	}
	if next == "fallback" && usable("primary") && e.health["primary"].good >= 6 && s.at-e.selectedAt >= 120 {
		next = "primary"
	}
	if next != e.selected {
		e.selected = next
		e.selectedAt = s.at
		emit("exit_changed", map[string]any{"selected": next, "existing_sessions": "retain_exit_or_fail"})
	}
}
func (cm *clientManager) transportsUnavailable() bool {
	cm.mu.Lock()
	s := cm.session
	cm.mu.Unlock()
	if s == nil || s.streams.IsClosed() {
		return true
	}
	s.mux.mu.Lock()
	defer s.mux.mu.Unlock()
	for _, p := range s.mux.paths {
		if p.ready && time.Since(p.lastPong) < 3500*time.Millisecond {
			return false
		}
	}
	return true
}
func (e *egressSelector) start() {
	for _, name := range []string{"primary", "fallback"} {
		go func(name string) {
			for {
				select {
				case <-e.done:
					return
				default:
				}
				started := time.Now()
				ok, wrong := e.probe(name)
				select {
				case e.samples <- exitSample{name, ok, wrong, bootSeconds()}:
				case <-e.done:
					return
				}
				// A warm independent path costs two small requests every 20 seconds.
				// Startup recovery and the active path are sampled every 8 seconds.
				e.mu.Lock()
				h := *e.health[name]
				active := e.selected == name
				e.mu.Unlock()
				delay := 10 * time.Second
				if !active && h.good >= 3 {
					delay = 20 * time.Second
				}
				delay -= time.Since(started)
				if delay < 500*time.Millisecond {
					delay = 500 * time.Millisecond
				}
				select {
				case <-time.After(delay):
				case <-e.done:
					return
				}
			}
		}(name)
	}
	go func() {
		for {
			select {
			case s := <-e.samples:
				e.ingest(s)
			case <-e.done:
				return
			}
		}
	}()
}
func allowedIP(text string, ips []string) bool {
	p := net.ParseIP(strings.TrimSpace(text))
	if p == nil {
		return false
	}
	for _, v := range ips {
		if p.Equal(net.ParseIP(v)) {
			return true
		}
	}
	return false
}
func (e *egressSelector) probe(name string) (bool, bool) {
	ips := e.cm.c.PrimaryIPs
	if name == "fallback" {
		ips = e.cm.c.FallbackIPs
	}
	tr := &http.Transport{Proxy: nil, DisableKeepAlives: true, ForceAttemptHTTP2: false,
		TLSHandshakeTimeout: 3 * time.Second, ResponseHeaderTimeout: 3 * time.Second,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			if name == "primary" {
				return e.cm.primaryDial(ctx, address)
			}
			return fallbackDial(ctx, e.cm.c, 1, hostAddress(address))
		}}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 4 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	verified, wrong := false, false
	// Failure/HTML from one measurement service is not proof of a wrong exit.
	for _, url := range []string{"https://www.cloudflare.com/cdn-cgi/trace", "https://api.ipify.org"} {
		req, _ := http.NewRequest(http.MethodGet, url, nil)
		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		b, err := io.ReadAll(io.LimitReader(resp.Body, 65537))
		resp.Body.Close()
		if err != nil || resp.StatusCode != 200 || len(b) > 65536 {
			continue
		}
		value := strings.TrimSpace(string(b))
		if strings.Contains(url, "cloudflare") {
			value = ""
			for _, line := range strings.Split(string(b), "\n") {
				if strings.HasPrefix(line, "ip=") {
					value = strings.TrimSpace(strings.TrimPrefix(line, "ip="))
				}
			}
		}
		if net.ParseIP(value) == nil {
			continue
		}
		if allowedIP(value, ips) {
			verified = true
		} else {
			wrong = true
		}
	}
	return verified && !wrong, wrong
}
func hostAddress(address string) []byte {
	host, port, _ := net.SplitHostPort(address)
	n, _ := strconv.Atoi(port)
	if ip := net.ParseIP(host); ip != nil {
		return addressBytes(&net.UDPAddr{IP: ip, Port: n})
	}
	if len(host) > 255 {
		return nil
	}
	return append(append([]byte{3, byte(len(host))}, host...), byte(n>>8), byte(n))
}
func (cm *clientManager) primaryDial(ctx context.Context, address string) (net.Conn, error) {
	s, err := cm.get()
	if err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	stream, err := s.streams.OpenStream()
	if err != nil {
		return nil, err
	}
	deadline, _ := ctx.Deadline()
	if deadline.IsZero() {
		deadline = time.Now().Add(4 * time.Second)
	}
	stream.SetDeadline(deadline)
	_, err = stream.Write(append([]byte{1}, hostAddress(address)...))
	ack := []byte{1}
	if err == nil {
		_, err = io.ReadFull(stream, ack)
	}
	if err != nil || ack[0] != 0 {
		stream.Close()
		return nil, errors.New("primary exit unavailable")
	}
	return stream, nil
}
func fallbackHandshake(ctx context.Context, c Config, command byte, address []byte) (net.Conn, []byte, error) {
	conn, err := (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, "tcp", c.FallbackProxy)
	if err != nil {
		return nil, nil, err
	}
	fail := func() (net.Conn, []byte, error) {
		conn.Close()
		return nil, nil, errors.New("independent proxy unavailable")
	}
	until, _ := ctx.Deadline()
	if until.IsZero() {
		until = time.Now().Add(6 * time.Second)
	}
	conn.SetDeadline(until)
	if _, err = conn.Write([]byte{5, 1, 2}); err != nil {
		return fail()
	}
	reply := make([]byte, 2)
	if _, err = io.ReadFull(conn, reply); err != nil || reply[0] != 5 || reply[1] != 2 {
		return fail()
	}
	if len(c.ProxyUser) > 255 || len(c.ProxyPassword) > 255 {
		return fail()
	}
	auth := append([]byte{1, byte(len(c.ProxyUser))}, c.ProxyUser...)
	auth = append(auth, byte(len(c.ProxyPassword)))
	auth = append(auth, c.ProxyPassword...)
	if _, err = conn.Write(auth); err != nil {
		return fail()
	}
	if _, err = io.ReadFull(conn, reply); err != nil || reply[0] != 1 || reply[1] != 0 {
		return fail()
	}
	if _, err = conn.Write(append([]byte{5, command, 0}, address...)); err != nil {
		return fail()
	}
	head := make([]byte, 3)
	if _, err = io.ReadFull(conn, head); err != nil || head[0] != 5 || head[1] != 0 || head[2] != 0 {
		return fail()
	}
	bound, raw, err := readAddress(conn)
	if err != nil {
		return fail()
	}
	if command == 3 {
		host, _, err := net.SplitHostPort(bound)
		if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
			return fail()
		}
	}
	return conn, raw, nil
}
func fallbackDial(ctx context.Context, c Config, command byte, address []byte) (net.Conn, error) {
	conn, _, err := fallbackHandshake(ctx, c, command, address)
	return conn, err
}
func forwardFallback(client net.Conn, c Config, command byte, address []byte) {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	upstream, bound, err := fallbackHandshake(ctx, c, command, address)
	if err != nil {
		socksReply(client, 1, nil)
		return
	}
	defer upstream.Close()
	if _, err = client.Write(append([]byte{5, 0, 0}, bound...)); err != nil {
		return
	}
	client.SetDeadline(time.Time{})
	upstream.SetDeadline(time.Time{})
	// UDP datagrams stay on the authenticated loopback association until either
	// control socket closes. No datagram is ever sent directly to the Internet.
	done := make(chan struct{}, 1)
	go func() {
		io.Copy(upstream, client)
		if tcp, ok := upstream.(*net.TCPConn); ok {
			tcp.CloseWrite()
		}
		done <- struct{}{}
	}()
	io.Copy(client, upstream)
	client.Close()
	upstream.Close()
	<-done
}
