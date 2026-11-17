// DualPath transport adapter: KCP reliability over two authenticated TLS paths.
// Derived from the separately verified LTE prototype; smux carries application streams.
package main

import (
	"bufio"
	"context"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	mrand "math/rand/v2"
	"net"
	"os"
	"sync"
	"time"

	kcp "github.com/xtaci/kcp-go/v5"
	"golang.org/x/net/proxy"
)

const L = 1024
const dataKind byte = 0
const pingKind byte = 1
const pongKind byte = 2
const startKind byte = 3
const closeKind byte = 4

type Config struct {
	FallbackProxy     string   `json:"fallback_proxy"`
	PrimaryIPs        []string `json:"primary_ips"`
	FallbackIPs       []string `json:"fallback_ips"`
	RuntimeGeneration string   `json:"runtime_generation"`
	ConfigHash        string   `json:"-"`
	BootID            string   `json:"boot_id"`
	NetworkEpoch      string   `json:"network_epoch"`
	ProxyUser         string   `json:"proxy_user"`
	ProxyPassword     string   `json:"proxy_password"`
	SocksUser         string   `json:"socks_user"`
	SocksPassword     string   `json:"socks_password"`
	Status            string   `json:"status"`
	AllowPrivate      bool     `json:"allow_private"`
	MaxSessions       int      `json:"max_sessions"`
	Role              string   `json:"role"`
	Listen            string   `json:"listen"`
	Upstream          string   `json:"upstream"`
	Cert              string   `json:"cert"`
	Key               string   `json:"key"`
	CA                string   `json:"ca"`
	Token             string   `json:"token"`
	ProxyA            string   `json:"proxy_a"`
	ProxyB            string   `json:"proxy_b"`
	TargetA           string   `json:"target_a"`
	TargetB           string   `json:"target_b"`
	ServerA           string   `json:"server_a"`
	ServerB           string   `json:"server_b"`
	SID               string   `json:"sid"`
	Mode              string   `json:"mode"`
	Scenario          string   `json:"scenario"`
	Profile           string   `json:"profile"`
	Seed              uint64   `json:"seed"`
	Operations        int      `json:"operations"`
	IntervalMs        int      `json:"interval_ms"`
	DeadlineMs        int      `json:"deadline_ms"`
	Chunks            int      `json:"chunks"`
	FaultStartMs      int      `json:"fault_start_ms"`
	FaultDurationMs   int      `json:"fault_duration_ms"`
}
type Hello struct {
	Token           string
	SID             string
	Mode            string
	Scenario        string
	Seed            uint64
	FaultStartMs    int
	FaultDurationMs int
}

var outMu sync.Mutex

func emit(kind string, v map[string]any) {
	outMu.Lock()
	defer outMu.Unlock()
	v["event"] = kind
	v["utc_ns"] = time.Now().UnixNano()
	b, _ := json.Marshal(v)
	fmt.Println(string(b))
}
func must(e error) {
	if e != nil {
		emit("fatal", map[string]any{"error": e.Error()})
		os.Exit(1)
	}
}
func frame(w io.Writer, k byte, b []byte) error {
	if len(b) > 65536 {
		return errors.New("oversized frame")
	}
	h := make([]byte, 5)
	h[0] = k
	binary.BigEndian.PutUint32(h[1:], uint32(len(b)))
	if _, e := w.Write(h); e != nil {
		return e
	}
	_, e := w.Write(b)
	return e
}
func readFrame(r io.Reader) (byte, []byte, error) {
	h := make([]byte, 5)
	if _, e := io.ReadFull(r, h); e != nil {
		return 0, nil, e
	}
	n := binary.BigEndian.Uint32(h[1:])
	if n > 65536 {
		return 0, nil, errors.New("oversized frame")
	}
	b := make([]byte, n)
	_, e := io.ReadFull(r, b)
	return h[0], b, e
}
func hello(r *bufio.Reader, token string) (Hello, error) {
	var h Hello
	b, e := r.ReadSlice('\n')
	if e != nil {
		return h, e
	}
	if len(b) > 4096 {
		return h, errors.New("oversized hello")
	}
	e = json.Unmarshal(b, &h)
	if e != nil {
		return h, e
	}
	if subtle.ConstantTimeCompare([]byte(h.Token), []byte(token)) != 1 || len(h.SID) != 32 {
		return h, errors.New("unauthorized session")
	}
	if _, e = hex.DecodeString(h.SID); e != nil {
		return h, e
	}
	return h, nil
}
func roots(c Config) *x509.CertPool {
	b, e := os.ReadFile(c.CA)
	must(e)
	p := x509.NewCertPool()
	if !p.AppendCertsFromPEM(b) {
		must(errors.New("CA parse"))
	}
	return p
}
func tlsServer(c Config) net.Listener {
	cert, e := tls.LoadX509KeyPair(c.Cert, c.Key)
	must(e)
	l, e := tls.Listen("tcp", c.Listen, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	must(e)
	return l
}
func dial(c Config, which string) (net.Conn, error) {
	target, paddr, sni := c.TargetA, c.ProxyA, c.ServerA
	if which == "B" {
		target, paddr, sni = c.TargetB, c.ProxyB, c.ServerB
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	var raw net.Conn
	var e error
	if paddr != "" {
		d, err := proxy.SOCKS5("tcp", paddr, &proxy.Auth{User: c.ProxyUser, Password: c.ProxyPassword}, &net.Dialer{Timeout: 5 * time.Second})
		if err != nil {
			return nil, err
		}
		if cd, ok := d.(proxy.ContextDialer); ok {
			raw, e = cd.DialContext(ctx, "tcp", target)
		} else {
			raw, e = d.Dial("tcp", target)
		}
	} else {
		raw, e = (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "tcp", target)
	}
	if e != nil {
		return nil, e
	}
	t := tls.Client(raw, &tls.Config{RootCAs: roots(c), ServerName: sni, MinVersion: tls.VersionTLS12})
	if e = t.HandshakeContext(ctx); e != nil {
		raw.Close()
		return nil, e
	}
	return t, nil
}

type packet struct {
	k   byte
	b   []byte
	due time.Time
}
type path struct {
	name           string
	c              net.Conn
	out            chan packet
	done           chan struct{}
	once           sync.Once
	ready          bool
	lastPong       time.Time
	streak, misses int
	rtt, delivery  time.Duration
	inflight       int
	samples        uint64
}
type routeRecord struct {
	path     string
	offset   uint64
	sent     time.Time
	size     int
	attempts int
	acked    bool
}
type mux struct {
	mu      sync.Mutex
	h       Hello
	client  bool
	paths   map[string]*path
	in      chan []byte
	done    chan struct{}
	once    sync.Once
	started time.Time
	offset  uint64
	seen    map[uint32]routeRecord
	maxSN   uint32
	active  string
	rng     *mrand.Rand
	stats   map[string]uint64
	maxQ    int
	last    time.Time
	ackDrop bool
}

func newMux(h Hello, client bool) *mux {
	m := &mux{h: h, client: client, paths: map[string]*path{}, in: make(chan []byte, 256), done: make(chan struct{}), seen: map[uint32]routeRecord{}, active: "B", rng: mrand.New(mrand.NewPCG(h.Seed, h.Seed+1)), stats: map[string]uint64{}, last: time.Now()}
	go m.probes()
	return m
}
func (m *mux) log(k string, v map[string]any) {
	v["sid"] = m.h.SID
	v["mode"] = m.h.Mode
	v["scenario"] = m.h.Scenario
	v["client"] = m.client
	emit(k, v)
}
func (m *mux) age() time.Duration {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.started.IsZero() {
		return -1
	}
	return time.Since(m.started)
}
func (m *mux) start() {
	m.mu.Lock()
	if m.started.IsZero() {
		m.started = time.Now()
		m.offset = 0
	}
	m.mu.Unlock()
}
func (m *mux) fault(name string, tx bool, k byte) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.client || m.started.IsZero() || k > pongKind {
		return false
	}
	t := time.Since(m.started)
	a := time.Duration(m.h.FaultStartMs) * time.Millisecond
	b := a + time.Duration(m.h.FaultDurationMs)*time.Millisecond
	if t < a || t >= b {
		return false
	}
	s := m.h.Scenario
	drop := (s == "blackhole_A" && name == "A") || (s == "blackhole_B" && name == "B") || (s == "A_out" && name == "A" && tx) || (s == "A_in" && name == "A" && !tx) || s == "common_outage"
	if drop {
		m.stats["fault_drops_"+name]++
	}
	return drop
}
func (m *mux) delay(name string, k byte) time.Duration {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.started.IsZero() {
		return 0
	}
	s := m.h.Scenario
	if s == "delay_A" && name == "A" {
		return 250 * time.Millisecond
	}
	if s == "slow_B" && name == "B" {
		return 250 * time.Millisecond
	}
	if s == "late_duplicate" && m.client && name == "B" && k == dataKind {
		return 900 * time.Millisecond
	}
	return 0
}
func (m *mux) fail(p *path) {
	p.once.Do(func() {
		close(p.done)
		p.c.Close()
		m.mu.Lock()
		if m.paths[p.name] == p {
			p.ready = false
		}
		m.mu.Unlock()
		m.log("path_connection_closed", map[string]any{"path": p.name})
	})
}
func (m *mux) add(name string, c net.Conn, r io.Reader) {
	p := &path{name: name, c: c, out: make(chan packet, 128), done: make(chan struct{}), lastPong: time.Now()}
	m.mu.Lock()
	old := m.paths[name]
	for _, rec := range m.seen {
		if rec.path == name && !rec.acked {
			p.inflight += rec.size
		}
	}
	m.paths[name] = p
	m.mu.Unlock()
	if old != nil {
		m.fail(old)
	}
	go func() {
		defer m.fail(p)
		for {
			select {
			case <-m.done:
				return
			case <-p.done:
				return
			case v := <-p.out:
				if d := time.Until(v.due); d > 0 {
					select {
					case <-time.After(d):
					case <-m.done:
						return
					case <-p.done:
						return
					}
				}
				if m.fault(name, true, v.k) {
					continue
				}
				p.c.SetWriteDeadline(time.Now().Add(5 * time.Second))
				if e := frame(p.c, v.k, v.b); e != nil {
					return
				}
				m.mu.Lock()
				m.stats["frame_bytes_sent_"+name] += uint64(5 + len(v.b))
				m.mu.Unlock()
			}
		}
	}()
	go func() {
		defer m.fail(p)
		for {
			k, b, e := readFrame(r)
			if e != nil {
				return
			}
			m.mu.Lock()
			m.last = time.Now()
			m.stats["frame_bytes_received_"+name] += uint64(len(b) + 5)
			m.mu.Unlock()
			if m.fault(name, false, k) {
				continue
			}
			switch k {
			case pingKind:
				m.enqueue(p, pongKind, b, false)
			case pongKind:
				m.mu.Lock()
				p.lastPong = time.Now()
				if len(b) == 8 {
					sample := time.Since(time.Unix(0, int64(binary.LittleEndian.Uint64(b))))
					if sample > 0 && sample < 10*time.Second {
						if p.rtt == 0 {
							p.rtt = sample
						} else {
							p.rtt = (p.rtt*7 + sample) / 8
						}
					}
				}
				p.misses = 0
				p.streak++
				was := p.ready
				if p.streak >= 2 {
					p.ready = true
				}
				becameReady := !was && p.streak == 2
				m.mu.Unlock()
				if becameReady {
					m.log("path_ready", map[string]any{"path": name})
				}
			case startKind:
				m.start()
			case closeKind:
				m.Close()
				return
			case dataKind:
				m.observeACK(b)
				select {
				case m.in <- b:
				case <-m.done:
					return
				}
			}
		}
	}()
}
func (m *mux) enqueue(p *path, k byte, b []byte, block bool) bool {
	v := packet{k, append([]byte(nil), b...), time.Now().Add(m.delay(p.name, k))}
	if block {
		for {
			select {
			case p.out <- v:
				m.mu.Lock()
				if len(p.out) > m.maxQ {
					m.maxQ = len(p.out)
				}
				m.mu.Unlock()
				return true
			case <-p.done:
				return false
			case <-m.done:
				return false
			case <-time.After(20 * time.Millisecond):
				m.mu.Lock()
				ready := p.ready
				m.mu.Unlock()
				if !ready {
					return false
				}
			}
		}
	}
	select {
	case p.out <- v:
		return true
	default:
		return false
	}
}
func (m *mux) probes() {
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-m.done:
			return
		case <-tick.C:
			m.mu.Lock()
			ps := []*path{}
			for _, p := range m.paths {
				if time.Since(p.lastPong) > 2500*time.Millisecond {
					p.misses++
					p.streak = 0
					if p.misses >= 2 && p.ready {
						p.ready = false
						go m.log("path_unavailable", map[string]any{"path": p.name})
					}
				}
				ps = append(ps, p)
			}
			m.mu.Unlock()
			for _, p := range ps {
				b := make([]byte, 8)
				binary.LittleEndian.PutUint64(b, uint64(time.Now().UnixNano()))
				m.enqueue(p, pingKind, b, false)
			}
		}
	}
}

// Adaptive heuristic: estimated delivery time multiplied by outstanding work.
// This is an experimental scheduler, not a bandwidth estimator or optimal policy.
func (m *mux) bestPathLocked() *path {
	var best *path
	bestScore := time.Duration(1<<63 - 1)
	for _, name := range []string{"B", "A"} {
		p := m.paths[name]
		if p == nil || !p.ready {
			continue
		}
		base := p.rtt
		if p.delivery > base {
			base = p.delivery
		}
		if base <= 0 {
			base = 100 * time.Millisecond
		}
		score := base + time.Duration(float64(base)*float64(p.inflight)/float64(4*L)) + time.Duration(len(p.out))*base/4
		if best == nil || score < bestScore {
			best = p
			bestScore = score
		}
	}
	return best
}
func (m *mux) observeACK(b []byte) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for off := 0; off+24 <= len(b); {
		n := int(binary.LittleEndian.Uint32(b[off+20 : off+24]))
		if n < 0 || off+24+n > len(b) {
			return
		}
		cmd := b[off+4]
		sn := binary.LittleEndian.Uint32(b[off+12 : off+16])
		una := binary.LittleEndian.Uint32(b[off+16 : off+20])
		off += 24 + n
		for seq, rec := range m.seen {
			if rec.acked || !(seq < una || (cmd == 82 && seq == sn)) {
				continue
			}
			if p := m.paths[rec.path]; p != nil {
				p.inflight -= rec.size
				if p.inflight < 0 {
					p.inflight = 0
				}
				if rec.attempts == 1 {
					d := time.Since(rec.sent)
					if p.delivery == 0 {
						p.delivery = d
					} else {
						p.delivery = (7*p.delivery + d) / 8
					}
					p.samples++
				}
			}
			rec.acked = true
			m.seen[seq] = rec
			m.stats["acked_payload_bytes_"+rec.path] += uint64(rec.size)
		}
	}
}

func (m *mux) choose(cmd byte, sn uint32, n int) (*path, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ready := func(s string) bool { p := m.paths[s]; return p != nil && p.ready }
	first := func() *path {
		if ready("B") {
			return m.paths["B"]
		}
		if ready("A") {
			return m.paths["A"]
		}
		return nil
	}
	if cmd != 81 {
		if m.h.Mode == "adaptive" {
			return m.bestPathLocked(), false
		}
		return first(), false
	}
	rec, repeat := m.seen[sn]
	want := "A"
	if repeat {
		want = "A"
		if rec.path == "A" {
			want = "B"
		}
		if !ready(want) {
			want = rec.path
		}
		m.stats["retry_segments"]++
	} else {
		switch m.h.Mode {
		case "B":
			want = "B"
		case "standby":
			if !ready(m.active) {
				if ready("B") {
					m.active = "B"
				} else if ready("A") {
					m.active = "A"
				}
			}
			want = m.active
		case "adaptive":
			if p := m.bestPathLocked(); p != nil {
				want = p.name
			}
		case "split":
			if (m.offset/L)%2 == 1 {
				want = "B"
			}
		}
		if !ready(want) {
			p := first()
			if p == nil {
				return nil, false
			}
			want = p.name
		}
		rec = routeRecord{path: want, offset: m.offset, size: n}
		m.offset += uint64(n)
		m.seen[sn] = rec
		if sn > m.maxSN {
			m.maxSN = sn
		}
		for old := range m.seen {
			if old+1024 < m.maxSN {
				delete(m.seen, old)
			}
		}
		m.stats["new_bytes_"+want] += uint64(n)
	}
	if !ready(want) {
		return nil, repeat
	}
	if repeat && !rec.acked {
		if prev := m.paths[rec.path]; prev != nil {
			prev.inflight -= rec.size
			if prev.inflight < 0 {
				prev.inflight = 0
			}
		}
	}
	rec.path = want
	rec.sent = time.Now()
	rec.attempts++
	if !rec.acked {
		m.paths[want].inflight += rec.size
	}
	m.seen[sn] = rec
	return m.paths[want], repeat
}
func (m *mux) WriteTo(b []byte, _ net.Addr) (int, error) {
	for off := 0; off+24 <= len(b); {
		n := int(binary.LittleEndian.Uint32(b[off+20 : off+24]))
		if n < 0 || off+24+n > len(b) {
			return 0, errors.New("KCP segment framing")
		}
		seg := b[off : off+24+n]
		cmd := seg[4]
		sn := binary.LittleEndian.Uint32(seg[12:16])
		off += 24 + n
		if !m.client && m.h.Scenario == "ack_loss" {
			a := m.age()
			if a >= time.Duration(m.h.FaultStartMs)*time.Millisecond && a < time.Duration(m.h.FaultStartMs+m.h.FaultDurationMs)*time.Millisecond {
				if cmd == 82 {
					m.mu.Lock()
					m.stats["suppressed_end_to_end_ACK"]++
					m.mu.Unlock()
					continue
				}
				seg = append([]byte(nil), seg...)
				binary.LittleEndian.PutUint32(seg[16:20], 0)
			}
		}
		for {
			p, _ := m.choose(cmd, sn, n)
			if p == nil {
				select {
				case <-m.done:
					return 0, net.ErrClosed
				default:
					// Like an unavailable UDP route, lose this transmission
					// attempt without blocking KCP's flush lock. Unacknowledged
					// data stays in its bounded send window for retransmission.
					m.mu.Lock()
					m.stats["no_ready_path_datagrams"]++
					m.mu.Unlock()
					return len(b), nil
				}
			}
			if m.client && m.h.Scenario == "loss_B" && p.name == "B" && cmd == 81 {
				m.mu.Lock()
				drop := m.rng.Float64() < .05
				if drop {
					m.stats["seeded_data_drops_B"]++
				}
				m.mu.Unlock()
				if drop {
					break
				}
			}
			if m.enqueue(p, dataKind, seg, true) {
				break
			}
		}
	}
	return len(b), nil
}
func (m *mux) ReadFrom(b []byte) (int, net.Addr, error) {
	select {
	case p := <-m.in:
		copy(b, p)
		ip := net.IPv4(10, 254, 0, 2)
		if m.client {
			ip = net.IPv4(10, 254, 0, 1)
		}
		return len(p), &net.UDPAddr{IP: ip, Port: 10000}, nil
	case <-m.done:
		return 0, nil, net.ErrClosed
	}
}
func (m *mux) Close() error {
	m.once.Do(func() {
		close(m.done)
		m.mu.Lock()
		ps := []*path{}
		for _, p := range m.paths {
			ps = append(ps, p)
		}
		m.mu.Unlock()
		for _, p := range ps {
			m.fail(p)
		}
	})
	return nil
}
func (m *mux) LocalAddr() net.Addr              { return &net.UDPAddr{IP: net.IPv4(10, 254, 0, 1), Port: 10000} }
func (m *mux) SetDeadline(time.Time) error      { return nil }
func (m *mux) SetReadDeadline(time.Time) error  { return nil }
func (m *mux) SetWriteDeadline(time.Time) error { return nil }
func (m *mux) waitReady(names []string, d time.Duration) bool {
	until := time.Now().Add(d)
	for time.Now().Before(until) {
		m.mu.Lock()
		ok := true
		for _, s := range names {
			p := m.paths[s]
			ok = ok && p != nil && p.ready
		}
		m.mu.Unlock()
		if ok {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}
func (m *mux) begin() {
	m.mu.Lock()
	ps := []*path{}
	for _, p := range m.paths {
		ps = append(ps, p)
	}
	m.mu.Unlock()
	for _, p := range ps {
		m.enqueue(p, startKind, nil, false)
	}
	m.start()
	time.Sleep(100 * time.Millisecond)
}
func tune(s *kcp.UDPSession) {
	s.SetMtu(L + 24)
	s.SetWindowSize(64, 64)
	s.SetStreamMode(true)
	s.SetACKNoDelay(true)
	s.SetNoDelay(1, 20, 2, 1)
}
