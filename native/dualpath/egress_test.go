package main

import (
	"context"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestExitAdmissionAndFailover(t *testing.T) {
	e := newEgressSelector(&clientManager{})
	if name, _ := e.current(1); name != "block" {
		t.Fatal("cold start admitted traffic")
	}
	for _, name := range []string{"primary", "fallback"} {
		for i := 0; i < 3; i++ {
			e.ingest(exitSample{name, true, false, 10 + float64(i)})
		}
	}
	if name, _ := e.current(13); name != "primary" {
		t.Fatal(name)
	}
	e.unavailable = func() bool { return false }
	e.ingest(exitSample{"primary", false, false, 14})
	e.ingest(exitSample{"primary", false, false, 15})
	if name, _ := e.current(16); name != "primary" {
		t.Fatal("one available transport triggered fast failover")
	}
	e.unavailable = func() bool { return true }
	e.ingest(exitSample{"primary", false, false, 17})
	if name, _ := e.current(18); name != "fallback" {
		t.Fatal(name)
	}
	if name, _ := e.current(60); name != "block" {
		t.Fatal("expired verification admitted traffic")
	}
	e.ingest(exitSample{"fallback", false, true, 61})
	if name, _ := e.current(61); name != "block" {
		t.Fatal("foreign IP admitted traffic")
	}
}
func TestFastFailureRequiresTwoSamplesAndWarmIndependentExit(t *testing.T) {
	e := newEgressSelector(&clientManager{})
	for i := 0; i < 3; i++ {
		e.ingest(exitSample{"primary", true, false, 10 + float64(i)})
		e.ingest(exitSample{"fallback", true, false, 10 + float64(i)})
	}
	e.ingest(exitSample{"primary", false, false, 13})
	if name, _ := e.current(13); name != "primary" {
		t.Fatal(name)
	}
	e.ingest(exitSample{"primary", false, false, 14})
	if name, _ := e.current(14); name != "fallback" {
		t.Fatal(name)
	}
	for i := 0; i < 7; i++ {
		e.ingest(exitSample{"primary", true, false, 15 + float64(i)})
	}
	if name, _ := e.current(22); name != "fallback" {
		t.Fatal("premature failback")
	}
	e.ingest(exitSample{"fallback", true, false, 140})
	e.ingest(exitSample{"primary", true, false, 141})
	if name, _ := e.current(141); name != "primary" {
		t.Fatal("stable preferred exit did not recover")
	}
}
func TestFallbackRejectsUnsafeConfiguration(t *testing.T) {
	c := Config{FallbackProxy: "127.0.0.1:10000", ProxyUser: "u", ProxyPassword: "p", PrimaryIPs: []string{"192.0.2.1"}, FallbackIPs: []string{"192.0.2.2"}}
	if validateFallback(c) != nil {
		t.Fatal("valid config rejected")
	}
	c.FallbackProxy = "192.0.2.3:10000"
	if validateFallback(c) == nil {
		t.Fatal("nonlocal proxy admitted")
	}
	c.FallbackProxy = "127.0.0.1:10000"
	c.FallbackIPs = c.PrimaryIPs
	if validateFallback(c) == nil {
		t.Fatal("shared exit admitted")
	}
	if !allowedIP("2001:0db8::1", []string{"2001:db8::1"}) || allowedIP("<html>failed</html>", []string{"192.0.2.1"}) {
		t.Fatal("IP parsing")
	}
}
func TestFallbackTCPAndUDPAssociation(t *testing.T) {
	for _, command := range []byte{1, 3} {
		t.Run(string(rune('0'+command)), func(t *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			c := Config{FallbackProxy: listener.Addr().String(), ProxyUser: "u", ProxyPassword: "p"}
			finished := make(chan error, 1)
			go func() {
				s, err := listener.Accept()
				if err != nil {
					finished <- err
					return
				}
				defer s.Close()
				err = authenticate(s, Config{SocksUser: "u", SocksPassword: "p"})
				if err != nil {
					finished <- err
					return
				}
				h := make([]byte, 3)
				_, err = io.ReadFull(s, h)
				if err != nil {
					finished <- err
					return
				}
				_, _, err = readAddress(s)
				if err != nil {
					finished <- err
					return
				}
				_, err = s.Write(append([]byte{5, 0, 0}, hostAddress("127.0.0.1:12345")...))
				if err != nil {
					finished <- err
					return
				}
				if command == 1 {
					b := make([]byte, 4)
					_, err = io.ReadFull(s, b)
					if err == nil {
						_, err = s.Write(b)
					}
				}
				finished <- err
			}()
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			conn, bound, err := fallbackHandshake(ctx, c, command, hostAddress("example.test:443"))
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			if len(bound) != 7 {
				t.Fatal("bad bind address")
			}
			if command == 1 {
				conn.Write([]byte("ping"))
				b := make([]byte, 4)
				if _, err = io.ReadFull(conn, b); err != nil || string(b) != "ping" {
					t.Fatal("TCP relay failed", err)
				}
			}
			if err = <-finished; err != nil {
				t.Fatal(err)
			}
		})
	}
}
func TestStatusPublicationFailurePreservesOldSnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "status.json")
	if err := atomicStatus(path, map[string]any{"state": "old"}); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path+".tmp", 0700); err != nil {
		t.Fatal(err)
	}
	if err := atomicStatus(path, map[string]any{"state": "new"}); err == nil {
		t.Fatal("write failure hidden")
	}
	b, _ := os.ReadFile(path)
	if string(b) != "{\"state\":\"old\"}" {
		t.Fatal("old status modified")
	}
}

func TestPongFreshnessIncludesSuspend(t *testing.T) {
	p := &path{ready: true, lastPong: time.Now(), lastPongBoot: 100}
	if !pathFresh(p, 101) {
		t.Fatal("fresh pong rejected")
	}
	if pathFresh(p, 110) || pathFresh(p, 99) {
		t.Fatal("stale/future pong admitted")
	}
}

func TestSessionWaitHasIndependentDeadline(t *testing.T) {
	cm := &clientManager{}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	started := time.Now()
	if _, err := cm.current(ctx); err == nil {
		t.Fatal("unavailable session admitted")
	}
	if time.Since(started) > time.Second {
		t.Fatal("probe waited for a shared dial")
	}
	cm.close()
	if _, err := cm.current(context.Background()); err == nil {
		t.Fatal("closed manager admitted traffic")
	}
}
