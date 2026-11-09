import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'card_store.dart';

abstract interface class BluetoothSyncLink {
  bool get central;
  Future<void> send(Uint8List frame);
  Future<Uint8List> receive();
}

class BluetoothSyncPeer {
  const BluetoothSyncPeer({required this.id, required this.name});

  final String id;
  final String name;
}

class BluetoothSyncResult {
  const BluetoothSyncResult({
    required this.sent,
    required this.received,
    required this.incomplete,
  });

  final int sent;
  final int received;
  final bool incomplete;
}

const maxBluetoothSyncFrameBytes = 16 * 1024;
const _keyLength = 32;
const _macLength = 16;
const _maxPayload = maxBluetoothSyncFrameBytes - _macLength - 1;
const _maxManifestBytes = 2 * 1024 * 1024;
const _manifestKeyLength = 64;
const _maxCards = _maxManifestBytes ~/ _manifestKeyLength;
const _maxCardBytes = CardStore.maxShareBytes;
const _maxIdentityBytes = 2048;
const _frameTimeout = Duration(seconds: 45);
const _inviteTimeout = Duration(minutes: 2);
final _random = Random.secure();
final _protocol = utf8.encode('loyalty-pocket-bluetooth/1');
final _aes = AesGcm.with256bits();
final _peerId = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');
final _unsafeName = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]',
);
final _manifestKey = RegExp(r'^[0-9a-f]{64}$');

enum _Kind {
  identity,
  invitation,
  joined,
  manifest,
  manifestPart,
  card,
  cardPart,
  cardReceipt,
  done,
}

enum _CardReceipt { present, imported, failed }

/// Runs one pairing and sync. The caller closes the link when it returns.
Future<BluetoothSyncResult?> runBluetoothSyncSession({
  required BluetoothSyncLink link,
  required CardStore store,
  required BluetoothSyncPeer local,
  Uint8List? groupKey,
  Uint8List? inviteKey,
  Uint8List? joinKey,
  Future<Uint8List?> Function(BluetoothSyncPeer peer)? acceptInvite,
  Future<void> Function(Uint8List groupKey, BluetoothSyncPeer peer)? onJoined,
  required void Function(BluetoothSyncPeer peer) onPeer,
}) async {
  final progress = _SyncProgress();
  var authenticated = false;
  try {
    final identity = _encodeIdentity(local);
    final hello = Uint8List.fromList([
      joinKey == null ? 0 : 1,
      for (var i = 0; i < _keyLength; i++) _random.nextInt(256),
    ]);
    final otherHello = await _ordered(
      link.central,
      () => link.send(hello).timeout(_frameTimeout),
      () => link.receive().timeout(_frameTimeout),
    );
    if (otherHello.length != hello.length || otherHello[0] > 1) return null;
    final joining = joinKey != null;
    final inviting = otherHello[0] == 1;
    if (joining && inviting) return null;
    final secret = joining ? joinKey : (inviting ? inviteKey : groupKey);
    if (secret == null ||
        secret.length != _keyLength ||
        (inviting && acceptInvite == null) ||
        (joining && onJoined == null)) {
      return null;
    }
    final channel = await _SecureLink.open(link, secret, hello, otherHello);
    final peer = _decodeIdentity(
      await _ordered(
        link.central,
        () => channel.send(_Kind.identity, identity),
        () => channel.receive(_Kind.identity),
      ),
    );
    if (peer.id == local.id) return null;

    if (inviting) {
      final acceptedKey = await acceptInvite!(peer);
      if (acceptedKey == null || acceptedKey.length != _keyLength) {
        await channel.send(_Kind.invitation);
        return null;
      }
      await channel.send(_Kind.invitation, acceptedKey);
      if ((await channel.receive(_Kind.joined)).isNotEmpty) return null;
    } else if (joining) {
      final acceptedKey = await channel.receive(
        _Kind.invitation,
        timeout: _inviteTimeout,
      );
      if (acceptedKey.length != _keyLength) return null;
      await onJoined!(acceptedKey, peer);
      authenticated = true;
      onPeer(peer);
      await channel.send(_Kind.joined);
    }
    if (!authenticated) {
      authenticated = true;
      onPeer(peer);
    }

    final manifest = await store.mergeManifest();
    final remoteKeys = await _ordered(
      link.central,
      () => _sendManifest(channel, manifest),
      () => _receiveManifest(channel),
    );
    if (link.central) {
      await _sendCards(channel, store, manifest, remoteKeys, progress);
      await _receiveCards(channel, store, progress);
    } else {
      await _receiveCards(channel, store, progress);
      await _sendCards(channel, store, manifest, remoteKeys, progress);
    }
    return progress.result();
  } on Object {
    if (!authenticated) return null;
    progress.incomplete = true;
    return progress.result();
  }
}

class _SyncProgress {
  int sent = 0;
  int received = 0;
  bool incomplete = false;

  BluetoothSyncResult result() => BluetoothSyncResult(
    sent: sent,
    received: received,
    incomplete: incomplete,
  );
}

Future<T> _ordered<T>(
  bool central,
  Future<void> Function() send,
  Future<T> Function() receive,
) async {
  if (central) {
    await send();
    return receive();
  }
  final value = await receive();
  await send();
  return value;
}

Uint8List _encodeIdentity(BluetoothSyncPeer peer) {
  if (!_peerId.hasMatch(peer.id) ||
      peer.name.trim().isEmpty ||
      _unsafeName.hasMatch(peer.name)) {
    throw const FormatException();
  }
  final encoded = utf8.encode(jsonEncode({'id': peer.id, 'name': peer.name}));
  if (encoded.length > _maxIdentityBytes) throw const FormatException();
  return encoded;
}

BluetoothSyncPeer _decodeIdentity(Uint8List bytes) {
  if (bytes.length > _maxIdentityBytes) throw const FormatException();
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded case {'id': final String id, 'name': final String name}
      when _peerId.hasMatch(id) &&
          name.trim().isNotEmpty &&
          !_unsafeName.hasMatch(name)) {
    return BluetoothSyncPeer(id: id, name: name);
  }
  throw const FormatException();
}

Future<void> _sendManifest(
  _SecureLink channel,
  List<MergeCardRef> manifest,
) async {
  final keys = {for (final card in manifest) ...card.keys};
  if (keys.length > _maxCards) throw const FormatException();
  final bytes = Uint8List.fromList(ascii.encode(keys.join()));
  await channel.send(_Kind.manifest, _length(bytes.length));
  await _sendParts(channel, _Kind.manifestPart, bytes);
}

Future<Set<String>> _receiveManifest(_SecureLink channel) async {
  final header = await channel.receive(_Kind.manifest);
  final length = _readLength(header, _maxManifestBytes);
  if (length % _manifestKeyLength != 0) throw const FormatException();
  final bytes = await _receiveParts(channel, _Kind.manifestPart, length);
  final keys = <String>{};
  for (var i = 0; i < length; i += _manifestKeyLength) {
    final key = ascii.decode(
      Uint8List.sublistView(bytes, i, i + _manifestKeyLength),
    );
    if (!_manifestKey.hasMatch(key)) throw const FormatException();
    keys.add(key);
  }
  return keys;
}

Future<void> _sendCards(
  _SecureLink channel,
  CardStore store,
  List<MergeCardRef> manifest,
  Set<String> remoteKeys,
  _SyncProgress progress,
) async {
  for (final card in manifest) {
    if (card.keys.any(remoteKeys.contains)) continue;
    Uint8List? bytes;
    try {
      bytes = await store.exportForMerge(card.id);
    } on Exception {
      // Treat a card changed or removed since the manifest as a partial sync.
    }
    if (bytes == null || bytes.isEmpty || bytes.length > _maxCardBytes) {
      progress.incomplete = true;
      continue;
    }
    await channel.send(_Kind.card, _length(bytes.length));
    await _sendParts(channel, _Kind.cardPart, bytes);
    final receipt = await channel.receive(_Kind.cardReceipt);
    if (receipt.length != 1 || receipt[0] >= _CardReceipt.values.length) {
      throw const FormatException();
    }
    final status = _CardReceipt.values[receipt[0]];
    switch (status) {
      case _CardReceipt.imported:
        progress.sent++;
        remoteKeys.addAll(card.keys);
      case _CardReceipt.present:
        remoteKeys.addAll(card.keys);
      case _CardReceipt.failed:
        progress.incomplete = true;
    }
  }
  await channel.send(_Kind.done, [progress.incomplete ? 1 : 0]);
}

Future<void> _receiveCards(
  _SecureLink channel,
  CardStore store,
  _SyncProgress progress,
) async {
  for (var received = 0; received <= _maxCards; received++) {
    final frame = await channel.read();
    if (frame.kind == _Kind.done) {
      if (frame.data.length != 1 || frame.data[0] > 1) {
        throw const FormatException();
      }
      if (frame.data[0] == 1) progress.incomplete = true;
      return;
    }
    if (frame.kind != _Kind.card || received == _maxCards) {
      throw const FormatException();
    }
    final length = _readLength(frame.data, _maxCardBytes);
    if (length == 0) throw const FormatException();
    final bytes = await _receiveParts(channel, _Kind.cardPart, length);
    _CardReceipt receipt;
    try {
      final imported = await store.importForMerge(bytes);
      if (imported) progress.received++;
      receipt = imported ? _CardReceipt.imported : _CardReceipt.present;
    } on Exception {
      progress.incomplete = true;
      receipt = _CardReceipt.failed;
    }
    await channel.send(_Kind.cardReceipt, [receipt.index]);
  }
}

Uint8List _length(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

int _readLength(Uint8List header, int max) {
  if (header.length != 4) throw const FormatException();
  final length = ByteData.sublistView(header).getUint32(0);
  if (length > max) throw const FormatException();
  return length;
}

Future<void> _sendParts(
  _SecureLink channel,
  _Kind kind,
  Uint8List bytes,
) async {
  for (var start = 0; start < bytes.length; start += _maxPayload) {
    final end = min(start + _maxPayload, bytes.length);
    await channel.send(kind, Uint8List.sublistView(bytes, start, end));
  }
}

Future<Uint8List> _receiveParts(
  _SecureLink channel,
  _Kind kind,
  int length,
) async {
  final result = Uint8List(length);
  for (var offset = 0; offset < length; offset += _maxPayload) {
    final part = await channel.receive(kind);
    final end = min(offset + _maxPayload, length);
    if (part.length != end - offset) throw const FormatException();
    result.setRange(offset, end, part);
  }
  return result;
}

class _SecureLink {
  _SecureLink(this._link, this._writeKey, this._readKey);

  final BluetoothSyncLink _link;
  final SecretKey _writeKey;
  final SecretKey _readKey;
  int _written = 0;
  int _read = 0;

  static Future<_SecureLink> open(
    BluetoothSyncLink link,
    Uint8List secret,
    Uint8List hello,
    Uint8List otherHello,
  ) async {
    // Bind both roles and join flags into the key derivation transcript.
    final salt = link.central
        ? [...hello, ...otherHello]
        : [...otherHello, ...hello];
    final material = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 2 * _keyLength,
    ).deriveKey(secretKey: SecretKey(secret), nonce: salt, info: _protocol);
    final centralKey = SecretKey(material.bytes.sublist(0, _keyLength));
    final peripheralKey = SecretKey(material.bytes.sublist(_keyLength));
    return link.central
        ? _SecureLink(link, centralKey, peripheralKey)
        : _SecureLink(link, peripheralKey, centralKey);
  }

  Future<void> send(_Kind kind, [List<int> body = const []]) async {
    if (body.length > _maxPayload) throw const FormatException();
    final clear = Uint8List(body.length + 1)
      ..[0] = kind.index
      ..setRange(1, body.length + 1, body);
    final box = await _aes.encrypt(
      clear,
      secretKey: _writeKey,
      nonce: _nonce(_written++),
    );
    final frame = Uint8List(clear.length + _macLength)
      ..setRange(0, clear.length, box.cipherText)
      ..setRange(clear.length, clear.length + _macLength, box.mac.bytes);
    await _link.send(frame).timeout(_frameTimeout);
  }

  Future<Uint8List> receive(
    _Kind expected, {
    Duration timeout = _frameTimeout,
  }) async {
    final frame = await read(timeout: timeout);
    if (frame.kind != expected) throw const FormatException();
    return frame.data;
  }

  Future<({_Kind kind, Uint8List data})> read({
    Duration timeout = _frameTimeout,
  }) async {
    final frame = await _link.receive().timeout(timeout);
    if (frame.length <= _macLength ||
        frame.length > maxBluetoothSyncFrameBytes) {
      throw const FormatException();
    }
    final macAt = frame.length - _macLength;
    final clear = await _aes.decrypt(
      SecretBox(
        Uint8List.sublistView(frame, 0, macAt),
        nonce: _nonce(_read++),
        mac: Mac(Uint8List.sublistView(frame, macAt)),
      ),
      secretKey: _readKey,
    );
    if (clear.isEmpty || clear[0] >= _Kind.values.length) {
      throw const FormatException();
    }
    return (
      kind: _Kind.values[clear[0]],
      data: clear is Uint8List
          ? Uint8List.sublistView(clear, 1)
          : Uint8List.fromList(clear.sublist(1)),
    );
  }

  static Uint8List _nonce(int sequence) =>
      (ByteData(12)..setUint64(4, sequence)).buffer.asUint8List();
}
