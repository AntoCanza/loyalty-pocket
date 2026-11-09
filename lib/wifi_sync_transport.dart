import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

import 'bluetooth_sync_link.dart';
import 'bluetooth_sync_protocol.dart';

const _serviceType = '_loyaltysync._tcp';
const _networkPoll = Duration(seconds: 6);
const _setupRetry = Duration(seconds: 18);
const _discoveryRenewal = Duration(minutes: 3);
const _syncCooldown = Duration(seconds: 40);
const _nsdTimeout = Duration(seconds: 12);
const _connectTimeout = Duration(seconds: 3);
const _cleanupTimeout = Duration(seconds: 4);
final _random = Random.secure();

/// Discovers wallet sessions without advertising a wallet name or identity.
class WifiSyncTransport {
  WifiSyncTransport({
    required void Function(WifiSyncLink) onLink,
    required void Function(bool) onAvailabilityChanged,
  }) : _onLink = onLink,
       _onAvailabilityChanged = onAvailabilityChanged;

  final void Function(WifiSyncLink) _onLink;
  final void Function(bool) _onAvailabilityChanged;
  final _clock = Stopwatch()..start();
  Future<void> _operations = Future.value();
  Future<bool>? _refreshing;
  Timer? _timer;
  _WifiNetwork? _network;
  Duration _nextSetup = Duration.zero;
  String? _interfaces;
  int _epoch = 0;
  bool _running = false;
  bool _available = false;

  Future<bool> start() {
    if (_running) return _refreshing ?? Future.value(_available);
    _running = true;
    _epoch++;
    _nextSetup = Duration.zero;
    _timer = Timer.periodic(_networkPoll, (_) => unawaited(_scheduleRefresh()));
    return _scheduleRefresh();
  }

  Future<void> stop() {
    _running = false;
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _refreshing = null;
    final network = _network;
    _network = null;
    final closing = network?.close();
    _setAvailable(false);
    return _serialize(() async {
      await closing;
    });
  }

  void syncNow() {
    if (!_running) return;
    final network = _network;
    if (network != null && network.ready) {
      network.syncNow();
    } else {
      _nextSetup = Duration.zero;
      unawaited(_scheduleRefresh());
    }
  }

  Future<bool> _scheduleRefresh() {
    final pending = _refreshing;
    if (pending != null) return pending;
    final epoch = _epoch;
    late final Future<bool> refresh;
    refresh = _serialize(() => _refresh(epoch)).whenComplete(() {
      if (identical(_refreshing, refresh)) _refreshing = null;
    });
    return _refreshing = refresh;
  }

  Future<bool> _refresh(int epoch) async {
    if (!_isCurrent(epoch)) return false;
    final interfaces = await _localInterfaces();
    if (!_isCurrent(epoch)) return false;
    final changed = interfaces != _interfaces;
    _interfaces = interfaces;
    final current = _network;
    if (current != null && (changed || !current.ready || current.shouldRenew)) {
      _network = null;
      final closing = current.close();
      _setAvailable(false);
      await closing;
    }
    if (!_isCurrent(epoch)) return false;
    if (_network case final network?) {
      network.refreshPeers();
      return true;
    }
    if (interfaces.isEmpty || (!changed && _clock.elapsed < _nextSetup)) {
      return false;
    }
    late final _WifiNetwork network;
    network = _WifiNetwork((link) {
      if (_isCurrent(epoch) && identical(_network, network)) {
        _onLink(link);
      } else {
        link.close();
      }
    });
    _network = network;
    try {
      await network.start();
    } on Object {
      if (identical(_network, network)) _network = null;
      await network.close();
      if (_isCurrent(epoch)) _nextSetup = _clock.elapsed + _setupRetry;
      return false;
    }
    if (!_isCurrent(epoch)) return false;
    _setAvailable(network.ready);
    return network.ready;
  }

  bool _isCurrent(int epoch) => _running && epoch == _epoch;

  void _setAvailable(bool value) {
    if (_available == value) return;
    _available = value;
    _onAvailabilityChanged(value);
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

class _WifiNetwork {
  _WifiNetwork(this._onLink);

  static const _maxInbound = 4;
  static const _maxOutbound = 3;
  static const _maxDialing = 2;
  static const _maxVisible = 64;

  final void Function(WifiSyncLink) _onLink;
  final _alias =
      'sync-${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}-'
      '${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}';
  final _clock = Stopwatch()..start();
  final _visible = <String, nsd.Service>{};
  final _lastAttempt = <String, Duration>{};
  final _dialing = <String>{};
  final _outgoing = <String, WifiSyncLink>{};
  final _incoming = <WifiSyncLink, String>{};
  ServerSocket? _server;
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  bool _closed = false;
  bool _serverFailed = false;

  bool get ready => !_closed && !_serverFailed && _discovery != null;
  bool get shouldRenew =>
      _clock.elapsed >= _discoveryRenewal &&
      _dialing.isEmpty &&
      _outgoing.isEmpty &&
      _incoming.isEmpty;

  Future<void> start() async {
    final server = await _bindServer();
    if (_closed) {
      await server.close();
      return;
    }
    _server = server;
    server.listen(
      _accept,
      onError: (Object _, StackTrace _) => _serverFailed = true,
      onDone: () => _serverFailed = true,
    );
    final registration = await _nsdResource(
      nsd.register(
        nsd.Service(name: _alias, type: _serviceType, port: server.port),
      ),
      nsd.unregister,
    );
    if (_closed) {
      await _closeResource(() => nsd.unregister(registration));
      return;
    }
    _registration = registration;
    // Resolve on demand so a device lost during a resolve does not reappear.
    final discovery = await _nsdResource(
      nsd.startDiscovery(_serviceType, autoResolve: false),
      nsd.stopDiscovery,
    );
    if (_closed) {
      await _closeResource(() => nsd.stopDiscovery(discovery));
      return;
    }
    _discovery = discovery;
    discovery.addListener(refreshPeers);
    refreshPeers();
  }

  void syncNow() {
    _lastAttempt.clear();
    refreshPeers();
  }

  void refreshPeers() {
    final discovery = _discovery;
    if (!ready || discovery == null) return;
    _visible.clear();
    for (final service in discovery.services) {
      final name = service.name;
      if (name == null ||
          name.isEmpty ||
          name == _alias ||
          name == _registration?.service.name) {
        continue;
      }
      _visible[name] = service;
      if (_visible.length >= _maxVisible) break;
    }
    _lastAttempt.removeWhere((name, _) => !_visible.containsKey(name));
    _pump();
  }

  void _pump() {
    if (!ready || _dialing.length >= _maxDialing) return;
    final now = _clock.elapsed;
    final eligible =
        _visible.entries.where((entry) {
          final name = entry.key;
          final last = _lastAttempt[name];
          return !_dialing.contains(name) &&
              !_outgoing.containsKey(name) &&
              (last == null || now - last >= _syncCooldown);
        }).toList()..sort(
          (a, b) => (_lastAttempt[a.key] ?? const Duration(seconds: -1))
              .compareTo(_lastAttempt[b.key] ?? const Duration(seconds: -1)),
        );
    for (final peer in eligible) {
      if (_dialing.length >= _maxDialing ||
          _dialing.length + _outgoing.length >= _maxOutbound) {
        break;
      }
      _lastAttempt[peer.key] = now;
      _dialing.add(peer.key);
      unawaited(_dial(peer.key, peer.value));
    }
  }

  Future<void> _dial(String name, nsd.Service service) async {
    try {
      final resolved = await nsd.resolve(service).timeout(_nsdTimeout);
      if (!_stillVisible(name, service)) return;
      final port = resolved.port;
      if (port == null || port < 1 || port > 65535) return;
      final addresses = await _peerAddresses(resolved);
      for (final address in addresses) {
        if (!_stillVisible(name, service)) return;
        final Socket socket;
        try {
          socket = await Socket.connect(
            address,
            port,
            timeout: _connectTimeout,
          );
        } on SocketException {
          continue;
        }
        if (!_stillVisible(name, service)) {
          socket.destroy();
          return;
        }
        final link = WifiSyncLink(
          socket,
          central: true,
          onClosed: () {
            _outgoing.remove(name);
            if (_visible.containsKey(name)) _lastAttempt[name] = _clock.elapsed;
            _pump();
          },
        );
        _outgoing[name] = link;
        _publish(link);
        return;
      }
    } on Object {
      // The service may have moved or disappeared between discovery and dialing.
    } finally {
      _dialing.remove(name);
      _pump();
    }
  }

  bool _stillVisible(String name, nsd.Service service) =>
      ready && identical(_visible[name], service);

  void _accept(Socket socket) {
    final remote = socket.remoteAddress;
    final address = remote.address;
    if (!ready ||
        !_localAddress(remote) ||
        _incoming.length >= _maxInbound ||
        _incoming.values.where((peer) => peer == address).length >= 2) {
      socket.destroy();
      return;
    }
    late final WifiSyncLink link;
    link = WifiSyncLink(
      socket,
      central: false,
      onClosed: () {
        _incoming.remove(link);
      },
    );
    _incoming[link] = address;
    _publish(link);
  }

  void _publish(WifiSyncLink link) {
    try {
      _onLink(link);
    } on Object {
      link.close();
    }
  }

  void _stopSockets() {
    if (_closed) return;
    _closed = true;
    _discovery?.removeListener(refreshPeers);
    final links = [..._outgoing.values, ..._incoming.keys];
    _outgoing.clear();
    _incoming.clear();
    _visible.clear();
    for (final link in links) {
      link.close();
    }
  }

  Future<void> close() async {
    _stopSockets();
    final discovery = _discovery;
    final registration = _registration;
    final server = _server;
    _discovery = null;
    _registration = null;
    _server = null;
    await Future.wait([
      if (server != null) _closeResource(server.close),
      if (discovery != null) _closeResource(() => nsd.stopDiscovery(discovery)),
      if (registration != null)
        _closeResource(() => nsd.unregister(registration)),
    ]);
  }
}

/// Carries ordered length-prefixed sync frames over a connected TCP socket.
class WifiSyncLink implements NearbySyncLink {
  WifiSyncLink(this._socket, {required this.central, void Function()? onClosed})
    : _onClosed = onClosed {
    _socket.done.ignore();
  }

  @override
  final bool central;
  final Socket _socket;
  final void Function()? _onClosed;
  late final _reader = StreamIterator(_socket);
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;
  bool _closed = false;

  @override
  Future<void> send(Uint8List frame) async {
    if (_closed) throw StateError('Wi-Fi sync link closed.');
    if (frame.isEmpty || frame.length > maxBluetoothSyncFrameBytes) {
      throw const FormatException('Invalid Wi-Fi sync frame length.');
    }
    final packet = Uint8List(frame.length + 2)
      ..[0] = frame.length >> 8
      ..[1] = frame.length & 0xff
      ..setRange(2, frame.length + 2, frame);
    _socket.add(packet);
    await _socket.flush();
  }

  @override
  Future<Uint8List> receive() async {
    final header = await _read(2);
    final length = (header[0] << 8) | header[1];
    if (length == 0 || length > maxBluetoothSyncFrameBytes) {
      close();
      throw const FormatException('Invalid Wi-Fi sync frame length.');
    }
    return _read(length);
  }

  Future<Uint8List> _read(int length) async {
    final bytes = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (_closed) throw StateError('Wi-Fi sync link closed.');
      if (_offset == _chunk.length) {
        if (!await _reader.moveNext() || _closed) {
          close();
          throw StateError('Wi-Fi sync link closed.');
        }
        _chunk = _reader.current;
        _offset = 0;
      }
      final count = min(length - written, _chunk.length - _offset);
      bytes.setRange(written, written + count, _chunk, _offset);
      written += count;
      _offset += count;
    }
    return bytes;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    _reader.cancel().ignore();
    _onClosed?.call();
  }
}

Future<ServerSocket> _bindServer() async {
  try {
    return await ServerSocket.bind(InternetAddress.anyIPv6, 0);
  } on SocketException {
    return ServerSocket.bind(InternetAddress.anyIPv4, 0);
  }
}

Future<T> _nsdResource<T>(
  Future<T> pending,
  Future<void> Function(T) cleanup,
) => pending.timeout(
  _nsdTimeout,
  onTimeout: () {
    pending
        .then<void>((value) => _closeResource(() => cleanup(value)))
        .ignore();
    throw TimeoutException('Local discovery timed out.');
  },
);

Future<void> _closeResource<T>(Future<T> Function() close) async {
  try {
    await close().timeout(_cleanupTimeout);
  } on Object {
    // The platform may already have removed the resource.
  }
}

Future<String> _localInterfaces() async {
  try {
    final interfaces = await NetworkInterface.list(includeLinkLocal: true);
    final addresses = [
      for (final interface in interfaces)
        for (final ip in interface.addresses.where(_localAddress))
          '${interface.index}/${interface.name}/${ip.address}',
    ]..sort();
    return addresses.join('\n');
  } on SocketException {
    return '';
  }
}

Future<List<InternetAddress>> _peerAddresses(nsd.Service service) async {
  var addresses = service.addresses;
  if (addresses == null || addresses.isEmpty) {
    final host = service.host;
    if (host == null || host.isEmpty) return const [];
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      addresses = [literal];
    } else {
      final name = host.toLowerCase();
      if (!name.endsWith('.local') && !name.endsWith('.local.')) {
        return const [];
      }
      addresses = await InternetAddress.lookup(host).timeout(_connectTimeout);
    }
  }
  final local = addresses.where(_localAddress).toSet();
  return [
    ...local.where((ip) => ip.type == InternetAddressType.IPv4),
    ...local.where((ip) => ip.type == InternetAddressType.IPv6),
  ].take(4).toList();
}

bool _localAddress(InternetAddress ip) {
  if (ip.isLoopback || ip.isMulticast) return false;
  if (ip.isLinkLocal) return true;
  final bytes = ip.rawAddress;
  if (bytes.length == 4) return _privateIpv4(bytes, 0);
  if (bytes.length != 16) return false;
  if ((bytes[0] & 0xfe) == 0xfc) return true;
  return bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 255 &&
      bytes[11] == 255 &&
      _privateIpv4(bytes, 12);
}

bool _privateIpv4(Uint8List bytes, int start) {
  final first = bytes[start];
  final second = bytes[start + 1];
  return first == 10 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 169 && second == 254);
}
