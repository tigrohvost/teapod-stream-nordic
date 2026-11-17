# DualPath runtime

Experimental managed Teapod profile for two authenticated transports: Naive on entry A and VLESS/XHTTP on entry B, both terminating at a common collector. KCP acknowledges delivery at the collector, and smux separates application streams. The proxy supports authenticated SOCKS5 CONNECT and UDP ASSOCIATE. Ordered DATA/FIN records preserve TCP half-close without closing a shared session prematurely.

The Android VPN service starts the bundled native Naive and DualPath executables, adds an authenticated internal Xray SOCKS inbound for the outer B connection, and points the managed outbound at DualPath. Internal listeners bind only to loopback; credentials and ports are regenerated for each VPN session. The app UID is excluded from its own TUN. Child processes are stopped on disconnect and restarted if they exit while the VPN is running. Path availability is reported in the connection log.

Managed JSON extension: `teapodDualPath` contains `version: 1`, `mode` (`adaptive`, `standby`, `split`), private `token`, CA PEM string `ca`, and `naive`, `xhttp`, `collector` endpoint objects. All endpoints require `address`, `port`, `serverName`; Naive requires `username`/`password`, XHTTP requires `uuid`/`path`. The managed outbound must have tag `teapod-dualpath`. This extension contains secrets; export only through the existing explicit full-backup flow. Never commit live profiles.

The collector requires TLS and the shared token, limits sessions and streams, and denies private/link-local/loopback egress by default. `allow_private` is only for integration tests. A failed individual transport reconnects with the same logical session. Loss of the collector or both transports can terminate application connections; the client then creates a fresh session. Two protocols still share the mobile radio and the collector. This does not promise independent physical paths, battery savings or universal resistance to filtering.

Build: Go 1.27.3, pinned modules in `dualpath/go.mod` and `go.sum`; `python3 tools/build_dualpath.py` verifies the Naive plugin archives listed in `runtime.lock.json` and creates Android native executables. The build workflow tests and signs the updated APK using the existing project signing identity.

Validate from repository root:

```sh
cd native/dualpath
go build -race -o /tmp/teapod-dualpath-test .
cd ../..
python3 tools/test_dualpath.py --binary /tmp/teapod-dualpath-test
```

Upstream dependencies: [KCP](https://github.com/xtaci/kcp-go), [smux](https://github.com/xtaci/smux), [NaiveProxy](https://github.com/klzgrad/naiveproxy). Their upstream licenses apply. The Naive SOCKS listener syntax with credentials follows the pinned upstream usage documentation.
