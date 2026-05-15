package libtailscale

import (
	"fmt"
	"reflect"
	"runtime"
	"sync"
	"unsafe"

	"github.com/LiuTangLei/wireguard-go/conn"
	"github.com/LiuTangLei/wireguard-go/device"
	"tailscale.com/wgengine"
	"tailscale.com/wgengine/magicsock"
)

//go:linkname resetMagicsockEndpointStates tailscale.com/wgengine/magicsock.(*Conn).resetEndpointStates
func resetMagicsockEndpointStates(*magicsock.Conn)

//go:linkname rebindMagicsockSockets tailscale.com/wgengine/magicsock.(*Conn).rebind
func rebindMagicsockSockets(*magicsock.Conn, uint8) error

//go:linkname receiveMagicsockIPv4 tailscale.com/wgengine/magicsock.(*Conn).receiveIPv4
func receiveMagicsockIPv4(*magicsock.Conn) conn.ReceiveFunc

//go:linkname receiveMagicsockIPv6 tailscale.com/wgengine/magicsock.(*Conn).receiveIPv6
func receiveMagicsockIPv6(*magicsock.Conn) conn.ReceiveFunc

type magicsockConnBind struct{}

//go:linkname receiveMagicsockDERP tailscale.com/wgengine/magicsock.(*connBind).receiveDERP
func receiveMagicsockDERP(*magicsockConnBind, [][]byte, []int, []conn.Endpoint) (int, error)

func restartWireGuardReceiveFuncs(engine wgengine.Engine, magicConn *magicsock.Conn) error {
	if engine == nil {
		return fmt.Errorf("nil wgengine")
	}
	if magicConn == nil {
		return fmt.Errorf("nil magicsock")
	}

	value := reflect.ValueOf(engine)
	if value.Kind() != reflect.Pointer || value.IsNil() {
		return fmt.Errorf("unexpected wgengine type %T", engine)
	}
	engineValue := value.Elem()

	wgdevField := engineValue.FieldByName("wgdev")
	if !wgdevField.IsValid() || wgdevField.Kind() != reflect.Pointer || wgdevField.IsNil() {
		return fmt.Errorf("wgengine %T has no live wgdev", engine)
	}
	wgdev := (*device.Device)(unsafe.Pointer(wgdevField.Pointer()))
	bind := magicConn.Bind()
	bindValue := reflect.ValueOf(bind)
	if bindValue.Kind() != reflect.Pointer || bindValue.IsNil() {
		return fmt.Errorf("unexpected magicsock bind type %T", bind)
	}
	connBind := (*magicsockConnBind)(unsafe.Pointer(bindValue.Pointer()))

	recvFns := []conn.ReceiveFunc{receiveMagicsockIPv4(magicConn), receiveMagicsockIPv6(magicConn), conn.ReceiveFunc(func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		return receiveMagicsockDERP(connBind, packets, sizes, eps)
	})}
	if runtime.GOOS == "js" {
		recvFns = recvFns[2:]
	}

	netStopping, err := waitGroupField(reflect.ValueOf(wgdev).Elem(), "net", "stopping")
	if err != nil {
		return err
	}
	decryptionWG, err := waitGroupField(reflect.ValueOf(wgdev).Elem(), "queue", "decryption", "wg")
	if err != nil {
		return err
	}
	handshakeWG, err := waitGroupField(reflect.ValueOf(wgdev).Elem(), "queue", "handshake", "wg")
	if err != nil {
		return err
	}

	if wgLockField := engineValue.FieldByName("wgLock"); wgLockField.IsValid() && wgLockField.CanAddr() {
		wgLock := (*sync.Mutex)(unsafe.Pointer(wgLockField.UnsafeAddr()))
		wgLock.Lock()
		defer wgLock.Unlock()
	}

	netStopping.Add(len(recvFns))
	decryptionWG.Add(len(recvFns))
	handshakeWG.Add(len(recvFns))
	batchSize := bind.BatchSize()
	for _, fn := range recvFns {
		go wgdev.RoutineReceiveIncoming(batchSize, fn)
	}
	return nil
}

func waitGroupField(value reflect.Value, path ...string) (*sync.WaitGroup, error) {
	field := value
	for _, name := range path {
		if field.Kind() == reflect.Pointer {
			if field.IsNil() {
				return nil, fmt.Errorf("nil field before %s", name)
			}
			field = field.Elem()
		}
		field = field.FieldByName(name)
		if !field.IsValid() {
			return nil, fmt.Errorf("missing field %s", name)
		}
	}
	if field.Kind() == reflect.Pointer {
		if field.IsNil() {
			return nil, fmt.Errorf("nil waitgroup field %v", path)
		}
		field = field.Elem()
	}
	if !field.CanAddr() {
		return nil, fmt.Errorf("waitgroup field %v is not addressable", path)
	}
	return (*sync.WaitGroup)(unsafe.Pointer(field.UnsafeAddr())), nil
}

// forceWireGuardPeerKeepalive walks every peer attached to the userspace
// wireguard device and sends a keepalive. Keepalive traversal causes
// wireguard-go to (re)establish a fresh session via handshake initiation when
// the current keypair is missing or expired, which is the only thing that
// shakes loose a "disco-up, transport-down" stall like the one observed on
// iOS after the underlay roams or the magicsock pconn churns.
func forceWireGuardPeerKeepalive(engine wgengine.Engine) (int, error) {
	if engine == nil {
		return 0, fmt.Errorf("nil wgengine")
	}
	v := reflect.ValueOf(engine)
	if v.Kind() != reflect.Pointer || v.IsNil() {
		return 0, fmt.Errorf("unexpected wgengine type %T", engine)
	}
	engineValue := v.Elem()
	wgdevField := engineValue.FieldByName("wgdev")
	if !wgdevField.IsValid() || wgdevField.Kind() != reflect.Pointer || wgdevField.IsNil() {
		return 0, fmt.Errorf("wgengine %T has no live wgdev", engine)
	}
	wgdev := (*device.Device)(unsafe.Pointer(wgdevField.Pointer()))

	peersField := reflect.ValueOf(wgdev).Elem().FieldByName("peers")
	if !peersField.IsValid() {
		return 0, fmt.Errorf("wgdev has no peers field")
	}
	rwLockPtr := (*sync.RWMutex)(unsafe.Pointer(peersField.FieldByName("RWMutex").UnsafeAddr()))
	keyMapField := peersField.FieldByName("keyMap")
	if !keyMapField.IsValid() {
		return 0, fmt.Errorf("wgdev peers has no keyMap")
	}
	keyMapPtr := unsafe.Pointer(keyMapField.UnsafeAddr())
	keyMap := *(*map[device.NoisePublicKey]*device.Peer)(keyMapPtr)

	rwLockPtr.RLock()
	peers := make([]*device.Peer, 0, len(keyMap))
	for _, p := range keyMap {
		peers = append(peers, p)
	}
	rwLockPtr.RUnlock()

	for _, p := range peers {
		p.SendKeepalive()
	}
	return len(peers), nil
}
