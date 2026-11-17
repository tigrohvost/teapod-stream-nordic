package main

// CLOCK_BOOTTIME includes suspend; Go's monotonic time.Since does not.
func pathFresh(p *path, now float64) bool {
	return p != nil && p.ready && p.lastPongBoot > 0 && now >= p.lastPongBoot && now-p.lastPongBoot < 3.5
}
