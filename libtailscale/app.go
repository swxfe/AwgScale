package libtailscale

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/feature/taildrop"
	"tailscale.com/hostinfo"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnauth"
	"tailscale.com/ipn/ipnlocal"
	"tailscale.com/ipn/localapi"
	"tailscale.com/logtail"
	"tailscale.com/net/netmon"
	"tailscale.com/net/netns"
	"tailscale.com/net/tsdial"
	"tailscale.com/paths"
	"tailscale.com/tsd"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/types/logid"
	"tailscale.com/util/eventbus"
	"tailscale.com/util/syspolicy/rsop"
	"tailscale.com/util/syspolicy/setting"
	"tailscale.com/wgengine"
	"tailscale.com/wgengine/netstack"
)

// App is the concrete iOS libtailscale runtime.
type App struct {
	dataDir        string
	directFileRoot string
	appCtx         AppContext
	cancel         context.CancelFunc
	stopOnce       sync.Once
	mu             sync.Mutex
	stopped        bool

	store             *stateStore
	policyStore       *syspolicyStore
	logIDPublicAtomic atomic.Pointer[logid.PublicID]

	localAPIHandler http.Handler
	backend         *ipnlocal.LocalBackend
	backendState    *backend // prevent GC; logIDPublicAtomic points into this
	ready           chan struct{}
	readyOnce       sync.Once
	readyErr        error
	packetCallback  PacketCallback
	tunnelConfigMgr tunnelConfigManager
}

type backend struct {
	engine      wgengine.Engine
	backend     *ipnlocal.LocalBackend
	sys         *tsd.System
	tunDev      *pendingTUN
	netMon      *netmon.Monitor
	logIDPublic logid.PublicID
	logger      *logtail.Logger
	bus         *eventbus.Bus
	appCtx      AppContext
}

func start(dataDir, directFileRoot string, hwAttestationPref bool, disableInterfaceBinding bool, appCtx AppContext) Application {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("panic in Start %s: %s", p, debug.Stack())
			panic(p)
		}
	}()

	initLogging(appCtx)
	netns.SetDisableBindConnToInterface(log.Printf, disableInterfaceBinding)

	if _, exists := os.LookupEnv("XDG_CACHE_HOME"); !exists {
		os.Setenv("XDG_CACHE_HOME", filepath.Join(dataDir, "cache"))
	}
	if _, exists := os.LookupEnv("XDG_CONFIG_HOME"); !exists {
		os.Setenv("XDG_CONFIG_HOME", filepath.Join(dataDir, "config"))
	}
	if _, exists := os.LookupEnv("HOME"); !exists {
		os.Setenv("HOME", dataDir)
	}

	return newApp(dataDir, directFileRoot, hwAttestationPref, appCtx)
}

func newApp(dataDir, directFileRoot string, hwAttestationPref bool, appCtx AppContext) *App {
	ctx, cancel := context.WithCancel(context.Background())
	a := &App{
		dataDir:        dataDir,
		directFileRoot: directFileRoot,
		appCtx:         appCtx,
		cancel:         cancel,
		ready:          make(chan struct{}),
	}

	a.store = newStateStore(appCtx)
	a.policyStore = &syspolicyStore{a: a}
	netmon.RegisterInterfaceGetter(a.getInterfaces)
	rsop.RegisterStore("DeviceHandler", setting.DeviceScope, a.policyStore)

	hwAttestEnabled := appCtx.HardwareAttestationKeySupported() && hwAttestationPref
	if hwAttestEnabled {
		key.RegisterHardwareAttestationKeyFns(
			func() key.HardwareAttestationKey { return emptyHardwareAttestationKey(appCtx) },
			func() (key.HardwareAttestationKey, error) { return createHardwareAttestationKey(appCtx) },
		)
	}

	go func() {
		defer func() {
			if p := recover(); p != nil {
				log.Printf("panic in runBackend %s: %s", p, debug.Stack())
				panic(p)
			}
		}()
		if err := a.runBackend(ctx, hwAttestEnabled); err != nil {
			a.markReady(err)
			if err != context.Canceled {
				log.Printf("fatal error: %v", err)
			}
		}
	}()

	return a
}

func (a *App) runBackend(ctx context.Context, hardwareAttestation bool) error {
	paths.AppSharedDir.Store(a.dataDir)
	hostinfo.SetOSVersion(a.osVersion())
	hostinfo.SetPackage(a.appCtx.GetInstallSource())
	hostinfo.SetDeviceModel(a.modelName())

	b, err := a.newBackend(a.dataDir, a.appCtx, a.store)
	if err != nil {
		return err
	}
	a.logIDPublicAtomic.Store(&b.logIDPublic)
	a.mu.Lock()
	if a.stopped || ctx.Err() != nil {
		a.mu.Unlock()
		a.closeBackendState(b)
		return context.Canceled
	}
	a.backend = b.backend
	a.backendState = b // prevent GC of backend struct while App is alive
	a.mu.Unlock()
	if hardwareAttestation {
		a.backend.SetHardwareAttested()
	}

	hc := localapi.HandlerConfig{
		Actor:    ipnauth.Self,
		Backend:  b.backend,
		Logf:     log.Printf,
		LogID:    *a.logIDPublicAtomic.Load(),
		EventBus: b.bus,
	}
	h := localapi.NewHandler(hc)
	h.PermitRead = true
	h.PermitWrite = true
	a.localAPIHandler = h

	<-ctx.Done()
	return ctx.Err()
}

func (a *App) newBackend(dataDir string, appCtx AppContext, store *stateStore) (*backend, error) {
	sys := tsd.NewSystem()
	sys.Set(store)

	logf := logger.RusagePrefixLog(log.Printf)
	tunDev := newPendingTUN()
	a.mu.Lock()
	if a.packetCallback != nil {
		tunDev.SetPacketCallback(a.packetCallback)
	}
	a.mu.Unlock()
	b := &backend{
		tunDev: tunDev,
		appCtx: appCtx,
		bus:    sys.Bus.Get(),
	}

	var logID logid.PrivateID
	if err := logID.UnmarshalText([]byte("dead0000dead0000dead0000dead0000dead0000dead0000dead0000dead0000")); err != nil {
		log.Printf("logID.UnmarshalText fallback: %v", err)
	}
	storedLogID, err := store.read(logPrefKey)
	if err != nil || storedLogID == nil {
		newLogID, err := logid.NewPrivateID()
		if err == nil {
			logID = newLogID
			if enc, err := newLogID.MarshalText(); err == nil {
				store.write(logPrefKey, enc)
			}
		}
	} else {
		if err := logID.UnmarshalText(storedLogID); err != nil {
			log.Printf("logID.UnmarshalText stored: %v", err)
		}
	}

	netMon, err := netmon.New(b.bus, logf)
	if err != nil {
		log.Printf("netmon.New: %v", err)
	}
	b.netMon = netMon
	b.setupLogs(dataDir, logID, logf, sys.HealthTracker.Get())
	a.tunnelConfigMgr.setDefaultRouteExcludeRoutes(b.defaultRouteExcludeRoutes)

	dialer := new(tsdial.Dialer)
	vf := &VPNFacade{
		SetBoth:           a.tunnelConfigMgr.onConfigUpdate,
		GetBaseConfigFunc: b.getDNSBaseConfig,
	}
	engine, err := wgengine.NewUserspaceEngine(logf, wgengine.Config{
		Tun:            b.tunDev,
		Router:         vf,
		DNS:            vf,
		ReconfigureVPN: vf.ReconfigureVPN,
		Dialer:         dialer,
		SetSubsystem:   sys.Set,
		NetMon:         netMon,
		HealthTracker:  sys.HealthTracker.Get(),
		Metrics:        sys.UserMetricsRegistry(),
		EventBus:       sys.Bus.Get(),
	})
	if err != nil {
		return nil, fmt.Errorf("runBackend: NewUserspaceEngine: %v", err)
	}
	b.engine = engine
	sys.Set(engine)
	b.logIDPublic = logID.Public()

	ns, err := netstack.Create(logf, sys.Tun.Get(), engine, sys.MagicSock.Get(), dialer, sys.DNSManager.Get(), sys.ProxyMapper())
	if err != nil {
		a.closeBackendState(b)
		return nil, fmt.Errorf("netstack.Create: %w", err)
	}
	sys.Set(ns)
	ns.ProcessLocalIPs = false // let NetworkExtension packetFlow feed local-IP traffic through WireGuard
	ns.ProcessSubnets = true
	// In-process clients (PeerAPI server, PeerAPI outbound dials via UseNetstackForIP)
	// register gVisor TCP/UDP endpoints on our local Tailnet IPs. Without this flag,
	// inbound reply packets to those local IPs would be forwarded to NEPacketTunnelFlow
	// and the iOS kernel (which has no matching socket) and dropped, causing every
	// Taildrop PUT to time out at the netstack TCP dial. See upstream tailscale#18423.
	ns.CheckLocalTransportEndpoints = true
	dialer.UseNetstackForIP = func(ip netip.Addr) bool {
		_, ok := engine.PeerForIP(ip)
		return ok
	}
	dialer.NetstackDialTCP = func(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
		conn, err := ns.DialContextTCP(ctx, dst)
		if err != nil {
			return nil, err
		}
		return conn, nil
	}
	dialer.NetstackDialUDP = func(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
		conn, err := ns.DialContextUDP(ctx, dst)
		if err != nil {
			return nil, err
		}
		return conn, nil
	}
	sys.NetstackRouter.Set(true)
	if w, ok := sys.Tun.GetOK(); ok {
		w.Start()
	}

	lb, err := ipnlocal.NewLocalBackend(logf, logID.Public(), sys, 0)
	if err != nil {
		a.closeBackendState(b)
		return nil, fmt.Errorf("runBackend: NewLocalBackend: %v", err)
	}
	if a.directFileRoot != "" {
		if err := os.MkdirAll(a.directFileRoot, 0o700); err != nil {
			log.Printf("taildrop: cannot create direct file root %q: %v", a.directFileRoot, err)
		} else if ext, ok := ipnlocal.GetExt[*taildrop.Extension](lb); ok {
			ext.SetDirectFileRoot(a.directFileRoot)
		} else {
			log.Printf("taildrop: extension unavailable")
		}
	}
	b.backend = lb
	if err := ns.Start(lb); err != nil {
		a.closeBackendState(b)
		return nil, fmt.Errorf("startNetstack: %w", err)
	}
	if b.logger != nil {
		lb.SetLogFlusher(b.logger.StartFlush)
	}
	b.sys = sys

	go func() {
		if err := lb.Start(ipn.Options{}); err != nil {
			a.markReady(err)
			log.Printf("Failed to start LocalBackend: %s", err)
			panic(err)
		}
		a.markReady(nil)
	}()

	return b, nil
}

// defaultRouteExcludeRoutes returns underlay routes that NEPacketTunnelProvider
// must keep outside the tunnel. When the tunnel installs a default route (exit
// node), Tailscale's local.go also adds the on-link LAN subnet to rs.Routes to
// prevent LAN leaks. On iOS that captures the LAN gateway into utun; once the
// ARP/ND cache expires, magicsock can no longer resolve the next hop. Excluding
// the full underlay subnet keeps gateway resolution on en0/pdp_ip0.
//
// iOS also does not reliably let IP_BOUND_IF override an NE default route for
// UDP destinations on the public internet, so direct peer endpoints need exact
// host-route exclusions too. This matches WireGuard-style NetworkExtension
// routing: the encrypted endpoint stays outside the full-tunnel default route,
// while decrypted traffic still follows the tunnel.
func (b *backend) defaultRouteExcludeRoutes() []netip.Prefix {
	if b == nil || b.netMon == nil {
		return nil
	}
	var out []netip.Prefix
	seen := make(map[netip.Prefix]bool)
	add := func(p netip.Prefix) bool {
		if !p.IsValid() {
			return false
		}
		addr := p.Addr()
		if addr.IsLoopback() || addr.IsUnspecified() || addr.IsLinkLocalUnicast() || addr.IsLinkLocalMulticast() || addr.IsMulticast() {
			return false
		}
		if seen[p] {
			return false
		}
		seen[p] = true
		out = append(out, p)
		return true
	}
	addAddr := func(addr netip.Addr) bool {
		addr = addr.Unmap()
		return add(netip.PrefixFrom(addr, addr.BitLen()))
	}
	addAddrString := func(s string) bool {
		if s == "" || s == "none" {
			return false
		}
		addr, err := netip.ParseAddr(s)
		if err != nil {
			return false
		}
		return addAddr(addr)
	}
	if state := b.netMon.InterfaceState(); state != nil && state.DefaultRouteInterface != "" {
		for _, pfx := range state.InterfaceIPs[state.DefaultRouteInterface] {
			add(pfx.Masked())
		}
	}
	if gw, _, ok := b.netMon.GatewayAndSelfIP(); ok && gw.IsValid() && !gw.IsLoopback() {
		add(netip.PrefixFrom(gw, gw.BitLen()))
	}
	if b.backend != nil {
		if nm := b.backend.NetMapWithPeers(); nm != nil {
			for _, peer := range nm.Peers {
				endpoints := peer.Endpoints()
				for i := 0; i < endpoints.Len(); i++ {
					addAddr(endpoints.At(i).Addr())
				}
			}
			if nm.DERPMap != nil {
				derpExcludeCountBefore := len(out)
				resolvedDERPHosts := make(map[string]bool)
				addDERPHost := func(host string) {
					if host == "" || host == "none" {
						return
					}
					if _, err := netip.ParseAddr(host); err == nil {
						addAddrString(host)
						return
					}
					if resolvedDERPHosts[host] {
						return
					}
					resolvedDERPHosts[host] = true
					ctx, cancel := context.WithTimeout(context.Background(), 750*time.Millisecond)
					addrs, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
					cancel()
					if err != nil {
						return
					}
					for _, addr := range addrs {
						addAddr(addr)
					}
				}
				for _, region := range nm.DERPMap.Regions {
					for _, node := range region.Nodes {
						addAddrString(node.IPv4)
						addAddrString(node.IPv6)
						addAddrString(node.STUNTestIP)
						addDERPHost(node.HostName)
					}
				}
				log.Printf("exit node: added %d DERP/STUN underlay route excludes from DERPMap", len(out)-derpExcludeCountBefore)
			}
		}
	}
	return out
}

func (a *App) osVersion() string {
	v, err := a.appCtx.GetOSVersion()
	if err != nil {
		panic(err)
	}
	return v
}

func (a *App) modelName() string {
	m, err := a.appCtx.GetDeviceName()
	if err != nil {
		panic(err)
	}
	return m
}

func (a *App) InjectInboundPacket(packet []byte) error {
	a.mu.Lock()
	b := a.backendState
	a.mu.Unlock()
	if b == nil || b.tunDev == nil {
		return os.ErrNotExist
	}
	return b.tunDev.InjectInboundPacket(packet)
}

func (a *App) SetPacketCallback(cb PacketCallback) {
	a.mu.Lock()
	a.packetCallback = cb
	b := a.backendState
	a.mu.Unlock()
	if b != nil && b.tunDev != nil {
		b.tunDev.SetPacketCallback(cb)
	}
}

func (a *App) RebindUnderlay(why string) {
	a.mu.Lock()
	b := a.backendState
	a.mu.Unlock()
	if b == nil {
		return
	}
	if b.netMon != nil {
		b.netMon.InjectEvent()
	}
	if b.sys == nil {
		return
	}
	magicConn, ok := b.sys.MagicSock.GetOK()
	if !ok || magicConn == nil {
		return
	}
	// Avoid magicConn.Rebind() here: the public method also probes and may close
	// DERP. The observed iOS failure is a dead WireGuard ReceiveFunc; do not use
	// wgdev.BindUpdate here because that closes magicsock's UDP pconn wrappers.
	// Refresh the sockets, reconnect DERP, then reattach fresh receive routines.
	log.Printf("magicsock: iOS underlay socket rebind + DERP reconnect + receive restart + endpoint reset + ReSTUN requested: %s", why)
	const keepCurrentPort = 0
	if err := rebindMagicsockSockets(magicConn, keepCurrentPort); err != nil {
		log.Printf("magicsock: iOS underlay socket rebind failed: %v", err)
	}
	if err := magicConn.DebugBreakDERPConns(); err != nil {
		log.Printf("magicsock: iOS DERP reconnect failed: %v", err)
	}
	if err := restartWireGuardReceiveFuncs(b.engine, magicConn); err != nil {
		log.Printf("magicsock: iOS receive restart failed: %v", err)
	} else {
		log.Printf("magicsock: iOS receive restart launched")
	}
	resetMagicsockEndpointStates(magicConn)
	magicConn.ReSTUN("ios-underlay-" + why)
	if n, err := forceWireGuardPeerKeepalive(b.engine); err != nil {
		log.Printf("magicsock: iOS peer keepalive kick failed: %v", err)
	} else {
		log.Printf("magicsock: iOS peer keepalive kick sent to %d peer(s)", n)
	}
}

func (a *App) Stop() {
	a.stopOnce.Do(func() {
		a.mu.Lock()
		cancel := a.cancel
		backend := a.backend
		backendState := a.backendState
		a.stopped = true
		a.backend = nil
		a.backendState = nil
		a.mu.Unlock()

		if cancel != nil {
			cancel()
		}
		a.markReady(context.Canceled)
		if backendState != nil {
			a.closeBackendState(backendState)
		} else if backend != nil {
			backend.Shutdown()
		}
	})
}

func (a *App) closeBackendState(backendState *backend) {
	if backendState == nil {
		return
	}
	if backendState.backend != nil {
		backendState.backend.Shutdown()
	} else if backendState.engine != nil {
		backendState.engine.Close()
	}
	if backendState.tunDev != nil {
		_ = backendState.tunDev.Close()
	}
	if backendState.netMon != nil {
		_ = backendState.netMon.Close()
	}
	if backendState.logger != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = backendState.logger.Shutdown(ctx)
	}
}

func (a *App) markReady(err error) {
	a.readyOnce.Do(func() {
		a.mu.Lock()
		if a.ready == nil {
			a.ready = make(chan struct{})
		}
		ready := a.ready
		a.readyErr = err
		a.mu.Unlock()
		close(ready)
	})
}

func (a *App) waitReady() error {
	a.mu.Lock()
	ready := a.ready
	a.mu.Unlock()
	if ready == nil {
		return os.ErrNotExist
	}
	<-ready
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.readyErr
}
