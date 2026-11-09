import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bluetooth_sync_link.dart';
import 'bluetooth_sync_protocol.dart';
import 'card_store.dart';
import 'wifi_sync_transport.dart';

enum BluetoothSyncStatus {
  disabled,
  starting,
  ready,
  permissionDenied,
  bluetoothOff,
  unavailable,
}

typedef BluetoothSyncEntry = ({
  DateTime time,
  String device,
  int sent,
  int received,
  bool incomplete,
});

class BluetoothSync extends ChangeNotifier {
  BluetoothSync({
    required CardStore store,
    required File settings,
    required VoidCallback onCardsChanged,
  }) : _store = store,
       _settings = settings,
       _onCardsChanged = onCardsChanged;

  static const _channel = MethodChannel('loyalty_pocket/bluetooth_sync');
  static const _invitePrefix = 'loyaltypocket:bluetooth:1:';
  static const _inviteLifetime = Duration(minutes: 5);
  static const _manualDiscoveryWindow = Duration(seconds: 45);
  static const _historyLimit = 20;
  static final _random = Random.secure();

  final CardStore _store;
  final File _settings;
  final VoidCallback _onCardsChanged;
  final _devices = <String, String>{};
  final _history = <BluetoothSyncEntry>[];
  final _links = <String, BluetoothPacketLink>{};
  final _peerLinks = <String, NearbySyncLink>{};
  final _superseded = <NearbySyncLink>{};
  late final _wifi = WifiSyncTransport(
    onLink: (link) {
      if (_acceptNewLinks && !_disposed) {
        unawaited(_session(link));
      } else {
        link.close();
      }
    },
    onAvailabilityChanged: (ready) {
      _wifiReady = ready;
      _changed();
    },
  );
  Future<void> _writes = Future.value();
  Future<void> _actions = Future.value();
  bool _disposed = false;
  bool _enabled = false;
  bool _initializing = true;
  bool _wifiReady = false;
  bool _manualActive = false;
  bool _manualDiscovering = false;
  bool _manualFoundPeer = false;
  bool _manualNoPeers = false;
  int _epoch = 0;
  var _status = BluetoothSyncStatus.disabled;
  late String _deviceId;
  late String _deviceName;
  Uint8List? _groupKey;
  Uint8List? _inviteKey;
  Uint8List? _joinKey;
  DateTime? _inviteExpiry;
  DateTime? _joinExpiry;
  Timer? _inviteTimer;
  Timer? _joinTimer;
  Timer? _manualTimer;

  bool get supported => Platform.isAndroid || Platform.isIOS;
  bool get initializing => _initializing;
  bool get hasGroup => _groupKey != null;
  bool get enabled => _enabled;
  bool get joining => _joinKey != null;
  bool get syncing => _peerLinks.isNotEmpty;
  bool get wifiReady => _wifiReady;
  bool get manualSyncActive => _manualActive;
  bool get manualSyncNoPeers => _manualNoPeers;
  String get deviceName => _deviceName;
  BluetoothSyncStatus get status => _status;
  String? get invitation =>
      _isLive(_inviteExpiry) ? '$_invitePrefix${_encode(_inviteKey!)}' : null;
  List<String> get devices => List.unmodifiable(_devices.values);
  List<BluetoothSyncEntry> get history => List.unmodifiable(_history);
  bool get _shouldRun => _enabled || joining || _manualActive;
  bool get _acceptNewLinks => _enabled || joining || _manualDiscovering;
  bool get _transportReady =>
      _wifiReady || _status == BluetoothSyncStatus.ready;

  Future<void> initialize() async {
    _deviceId = _encode(_randomBytes(16));
    _deviceName =
        '${Platform.isIOS ? 'iPhone' : 'Android'} '
        '${_deviceId.substring(0, 4)}';
    try {
      if (await _settings.exists()) {
        _loadSettings(jsonDecode(await _settings.readAsString()));
      }
      if (supported && !_disposed) {
        _channel.setMethodCallHandler(_onNative);
        final key = await _channel.invokeMethod<Uint8List>('readGroupKey');
        if (key?.length == 32) _groupKey = key;
      }
    } on Exception {
      _status = BluetoothSyncStatus.unavailable;
    } finally {
      _enabled = _enabled && hasGroup;
      _initializing = false;
      _changed();
    }
    if (_enabled) {
      await resume();
    } else if (hasGroup && !_disposed) {
      await _act(_stop);
    }
  }

  Future<void> resume() => _act(() async {
    if (!_initializing &&
        _shouldRun &&
        (!_wifiReady || _status != BluetoothSyncStatus.ready)) {
      await _start(prompt: false);
    }
  });

  Future<void> syncNow() => _act(() async {
    if (!hasGroup || _manualActive || _disposed) return;
    _manualActive = true;
    _manualDiscovering = true;
    _manualFoundPeer = syncing;
    _manualNoPeers = false;
    _changed();
    await _start(prompt: true, enableRadio: true);
    if (_disposed) return;
    _manualTimer = Timer(_manualDiscoveryWindow, () {
      unawaited(
        _act(() async {
          _manualDiscovering = false;
          await _finishManualSync();
        }),
      );
    });
  });

  Future<void> _finishManualSync() async {
    if (!_manualActive || _manualDiscovering || syncing) return;
    _manualActive = false;
    _manualNoPeers = !_manualFoundPeer;
    if (!_shouldRun) await _stop();
    _changed();
  }

  void _resetManualSync() {
    _manualTimer?.cancel();
    _manualActive = false;
    _manualDiscovering = false;
    _manualNoPeers = false;
  }

  Future<void> rename(String name) => _act(() async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || utf8.encode(trimmed).length > 160) return;
    _deviceName = trimmed;
    await _save();
    _changed();
  });

  Future<void> setEnabled(bool enabled) => _act(() async {
    if (!hasGroup) return;
    _enabled = enabled;
    if (enabled) {
      await _save();
      await _start(prompt: true);
    } else {
      _clearInvite();
      _resetManualSync();
      await _stop();
      await _save();
    }
  });

  Future<String?> createInvitation() => _act(() async {
    if (!supported || joining) return null;
    if (!hasGroup) {
      final key = _randomBytes(32);
      await _channel.invokeMethod<void>('writeGroupKey', key);
      _groupKey = key;
    }
    _enabled = true;
    await _save();
    await _start(prompt: true);
    if (!_transportReady) return null;
    _clearInvite();
    _inviteKey = _randomBytes(32);
    _inviteExpiry = DateTime.now().add(_inviteLifetime);
    _inviteTimer = Timer(_inviteLifetime, _clearInvite);
    _changed();
    return invitation;
  });

  void closeInvitation(String code) {
    if (invitation == code) _clearInvite();
  }

  static bool isInvitation(String value) => _decodeInvitation(value) != null;

  Future<bool> joinInvitation(String code) => _act(() async {
    final key = _decodeInvitation(code);
    if (!supported || hasGroup || key == null) return false;
    _joinKey = key;
    _joinExpiry = DateTime.now().add(_inviteLifetime);
    _joinTimer?.cancel();
    _joinTimer = Timer(_inviteLifetime, () => unawaited(cancelJoin()));
    await _start(prompt: true);
    if (!_transportReady) {
      final failure = _status;
      _clearJoin();
      await _stop();
      _status = failure;
      _changed();
      return false;
    }
    return true;
  });

  Future<void> cancelJoin() => _act(() async {
    if (!joining) return;
    _clearJoin();
    if (!_enabled) await _stop();
  });

  Future<void> leave() => _act(() async {
    _enabled = false;
    _resetManualSync();
    _clearInvite();
    _clearJoin();
    await _stop();
    await _channel.invokeMethod<void>('writeGroupKey');
    _groupKey = null;
    _devices.clear();
    _history.clear();
    await _save();
    _changed();
  });

  Future<void> _start({required bool prompt, bool enableRadio = false}) async {
    if (!supported || _disposed) {
      _status = BluetoothSyncStatus.unavailable;
      _changed();
      return;
    }
    final wifi = _startWifi(refresh: enableRadio);
    if (_status != BluetoothSyncStatus.ready || enableRadio) {
      _status = BluetoothSyncStatus.starting;
      _changed();
      try {
        final value = await _channel.invokeMethod<String>('start', {
          'prompt': prompt,
          'enableRadio': enableRadio,
          'keepAlive': true,
        });
        _status = _statusFromNative(value);
      } on Exception {
        _status = BluetoothSyncStatus.unavailable;
      }
    }
    await wifi;
    _changed();
  }

  Future<void> _startWifi({required bool refresh}) async {
    try {
      _wifiReady = await _wifi.start();
      if (refresh && !_disposed) _wifi.syncNow();
    } on Exception {
      _wifiReady = false;
    }
    _changed();
  }

  Future<void> _stop() async {
    _epoch++;
    for (final link in _links.values) {
      link.close();
    }
    _links.clear();
    _peerLinks.clear();
    _superseded.clear();
    if (supported) {
      final wifi = _wifi.stop();
      try {
        await _channel.invokeMethod<void>('stop');
      } on Exception {
        // The platform may have stopped already.
      }
      await wifi;
    }
    _wifiReady = false;
    _status = BluetoothSyncStatus.disabled;
    _changed();
  }

  Future<void> _onNative(MethodCall call) async {
    if (_disposed || !_shouldRun) return;
    if (call.method == 'status') {
      _status = _statusFromNative(call.arguments);
      _changed();
      return;
    }
    final args = call.arguments;
    if (args is! Map || args['id'] is! String) return;
    final id = args['id'] as String;
    switch (call.method) {
      case 'peerConnected':
        if (_links.containsKey(id)) return;
        final central = args['central'];
        final maxPacketBytes = args['maxPacketBytes'];
        if (!_acceptNewLinks ||
            central is! bool ||
            maxPacketBytes is! int ||
            _links.length >= 4) {
          await _disconnect(id);
          return;
        }
        final link = BluetoothPacketLink(
          central: central,
          maxPacketBytes: maxPacketBytes,
          sendPacket: (bytes) =>
              _channel.invokeMethod<void>('send', {'id': id, 'bytes': bytes}),
        );
        _links[id] = link;
        unawaited(_session(link, bluetoothId: id));
      case 'bytesReceived':
        final bytes = args['bytes'];
        final link = _links[id];
        if (bytes is Uint8List && link != null && !link.addPacket(bytes)) {
          link.close();
          await _disconnect(id);
        }
      case 'peerDisconnected':
        _links.remove(id)?.endInput();
    }
  }

  Future<void> _session(NearbySyncLink link, {String? bluetoothId}) async {
    final epoch = _epoch;
    final local = BluetoothSyncPeer(id: _deviceId, name: _deviceName);
    final offer = _isLive(_inviteExpiry) ? _inviteKey : null;
    final join = _isLive(_joinExpiry) ? _joinKey : null;
    BluetoothSyncPeer? peer;
    BluetoothSyncResult? result;
    try {
      result = await runBluetoothSyncSession(
        link: link,
        store: _store,
        local: local,
        groupKey: _groupKey,
        inviteKey: offer,
        joinKey: join,
        acceptInvite: (remote) async {
          if (offer == null ||
              offer != _inviteKey ||
              !_isLive(_inviteExpiry) ||
              epoch != _epoch) {
            return null;
          }
          _clearInvite();
          return _groupKey;
        },
        onJoined: (key, remote) => _act(() async {
          if (join == null ||
              join != _joinKey ||
              !_isLive(_joinExpiry) ||
              epoch != _epoch) {
            throw StateError('Bluetooth invitation expired.');
          }
          await _channel.invokeMethod<void>('writeGroupKey', key);
          _groupKey = key;
          _enabled = true;
          _devices[remote.id] = remote.name;
          _clearJoin();
          await _save();
        }),
        onPeer: (remote) {
          if (epoch != _epoch || _disposed) {
            link.close();
            return;
          }
          peer = remote;
          if (_manualActive) _manualFoundPeer = true;
          _manualNoPeers = false;
          final other = _peerLinks[remote.id];
          if (other != null) {
            final preferCentral = local.id.compareTo(remote.id) < 0;
            final thisIsWifi = link is WifiSyncLink;
            final otherIsWifi = other is WifiSyncLink;
            final preferNew = thisIsWifi != otherIsWifi
                ? thisIsWifi
                : link.central == preferCentral &&
                      other.central != preferCentral;
            if (!preferNew) {
              _superseded.add(link);
              link.close();
              return;
            }
            _superseded.add(other);
            other.close();
          }
          _peerLinks[remote.id] = link;
          _devices[remote.id] = remote.name;
          _changed();
        },
      );
    } catch (_) {
      // A radio can disconnect at any time. Already imported cards stay saved.
    } finally {
      link.close();
      if (bluetoothId != null && _links[bluetoothId] == link) {
        _links.remove(bluetoothId);
        await _disconnect(bluetoothId);
      }
      if (_peerLinks[peer?.id] == link) {
        _peerLinks.remove(peer?.id);
        _changed();
      }
      if (_manualActive && !_manualDiscovering) {
        unawaited(_act(_finishManualSync));
      }
    }
    final superseded = _superseded.remove(link);
    if (_disposed) return;
    if ((result?.received ?? 0) > 0) _onCardsChanged();
    final remote = peer;
    if (epoch != _epoch || remote == null || superseded) return;
    final entry = (
      time: DateTime.now(),
      device: remote.name,
      sent: result?.sent ?? 0,
      received: result?.received ?? 0,
      incomplete: result?.incomplete ?? true,
    );
    if (_history.isNotEmpty &&
        entry.sent == 0 &&
        entry.received == 0 &&
        !entry.incomplete &&
        _history.first.device == entry.device &&
        _history.first.sent == 0 &&
        _history.first.received == 0 &&
        !_history.first.incomplete) {
      _history[0] = entry;
    } else {
      _history.insert(0, entry);
      if (_history.length > _historyLimit) _history.removeLast();
    }
    _changed();
    try {
      await _save();
    } on FileSystemException {
      // History remains available for this app session.
    }
  }

  Future<void> _disconnect(String id) async {
    try {
      await _channel.invokeMethod<void>('disconnect', {'id': id});
    } on Exception {
      // The peer may have disconnected already.
    }
  }

  void _clearInvite() {
    _inviteTimer?.cancel();
    _inviteKey = null;
    _inviteExpiry = null;
    _changed();
  }

  void _clearJoin() {
    _joinTimer?.cancel();
    _joinKey = null;
    _joinExpiry = null;
    _changed();
  }

  Future<T> _act<T>(Future<T> Function() action) {
    final next = _actions.then((_) => action());
    _actions = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _save() {
    final next = _writes.then((_) async {
      final temporary = File('${_settings.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'id': _deviceId,
          'name': _deviceName,
          'enabled': _enabled,
          'devices': _devices,
          'history': [
            for (final entry in _history)
              {
                'time': entry.time.toIso8601String(),
                'device': entry.device,
                'sent': entry.sent,
                'received': entry.received,
                'incomplete': entry.incomplete,
              },
          ],
        }),
        flush: true,
      );
      await temporary.rename(_settings.path);
    });
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _loadSettings(Object? value) {
    if (value is! Map) return;
    final id = value['id'];
    final name = value['name'];
    if (id is String && id.isNotEmpty) _deviceId = id;
    if (name is String && name.isNotEmpty) _deviceName = name;
    _enabled = value['enabled'] == true;
    final devices = value['devices'];
    if (devices is Map) {
      for (final entry in devices.entries) {
        if (entry.key is String && entry.value is String) {
          _devices[entry.key as String] = entry.value as String;
        }
      }
    }
    final history = value['history'];
    if (history is! List) return;
    for (final entry in history.take(_historyLimit)) {
      if (entry is! Map) continue;
      final date = entry['time'];
      final time = date is String ? DateTime.tryParse(date) : null;
      final device = entry['device'];
      final sent = entry['sent'];
      final received = entry['received'];
      if (time != null && device is String && sent is int && received is int) {
        _history.add((
          time: time,
          device: device,
          sent: sent,
          received: received,
          incomplete: entry['incomplete'] == true,
        ));
      }
    }
  }

  static BluetoothSyncStatus _statusFromNative(Object? value) =>
      switch (value) {
        'ready' => BluetoothSyncStatus.ready,
        'permissionDenied' => BluetoothSyncStatus.permissionDenied,
        'bluetoothOff' => BluetoothSyncStatus.bluetoothOff,
        _ => BluetoothSyncStatus.unavailable,
      };

  static Uint8List? _decodeInvitation(String value) {
    if (!value.startsWith(_invitePrefix) ||
        value.length != _invitePrefix.length + 43) {
      return null;
    }
    try {
      final key = base64Url.decode('${value.substring(_invitePrefix.length)}=');
      return key.length == 32 ? key : null;
    } on FormatException {
      return null;
    }
  }

  static Uint8List _randomBytes(int count) =>
      Uint8List.fromList(List.generate(count, (_) => _random.nextInt(256)));

  static bool _isLive(DateTime? expiry) =>
      expiry != null && DateTime.now().isBefore(expiry);

  static String _encode(Uint8List bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _inviteTimer?.cancel();
    _joinTimer?.cancel();
    _manualTimer?.cancel();
    if (supported) _channel.setMethodCallHandler(null);
    unawaited(_stop());
    super.dispose();
  }
}
