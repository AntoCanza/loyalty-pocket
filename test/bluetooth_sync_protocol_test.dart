import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/bluetooth_sync_link.dart';
import 'package:loyalty_pocket/bluetooth_sync_protocol.dart';
import 'package:loyalty_pocket/card_store.dart';

final _groupKey = Uint8List.fromList(List.filled(32, 23));
final _inviteKey = Uint8List.fromList(List.filled(32, 37));
final _otherKey = Uint8List.fromList(List.filled(32, 42));

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('loyalty-bluetooth-');
    addTearDown(() => root.delete(recursive: true));
  });

  test(
    'relays cards through four wallets and keeps local duplicates',
    () async {
      final a = _Wallet(root, 'Alpha');
      final b = _Wallet(root, 'Beta');
      final c = _Wallet(root, 'Charlie');
      final d = _Wallet(root, 'Delta');
      final original = _largePng();
      final photo = await File(
        '${root.path}/market.png',
      ).writeAsBytes(original);
      await a.store.save(name: 'Market', photo: photo, code: '001');
      await b.store.save(name: 'Bookshop', photo: null, code: '002');
      await c.store.save(name: 'Stationery', photo: null, code: '003');
      await d.store.save(name: 'Bakery', photo: null, code: '004');
      final alphaCoffee = await a.store.save(
        name: 'Alpha Coffee',
        note: 'My first card',
        photo: photo,
        code: '000',
      );
      final deltaCoffee = await d.store.save(
        name: 'Delta Coffee',
        note: 'My newer card',
        photo: null,
        code: '000',
      );
      await photo.delete();

      _expectPair(await _sync(a, b), sent: 2, received: 1);
      _expectPair(await _sync(c, d), sent: 1, received: 2);
      _expectPair(await _sync(b, c), sent: 2, received: 2);
      _expectPair(await _sync(a, b), sent: 0, received: 2);
      _expectPair(await _sync(c, d), sent: 2, received: 0);
      _expectPair(await _sync(d, a), sent: 0, received: 0);

      for (final (wallet, coffee) in [
        (a, alphaCoffee),
        (b, alphaCoffee),
        (c, deltaCoffee),
        (d, deltaCoffee),
      ]) {
        final cards = await wallet.store.load();
        expect(
          cards.map((card) => card.code),
          unorderedEquals(['000', '001', '002', '003', '004']),
        );
        final duplicate = cards.singleWhere((card) => card.code == '000');
        expect(duplicate.id, coffee.id);
        expect(duplicate.name, coffee.name);
        expect(duplicate.note, coffee.note);
        final market = cards.singleWhere((card) => card.code == '001');
        expect(await File(market.photoPath!).readAsBytes(), original);
      }
    },
  );

  test(
    '15 moving phone and tablet profiles converge after partition and photo loss',
    () async {
      const profiles = ['Android phone', 'iPhone', 'Android tablet', 'iPad'];
      const packetSizes = [512, 180, 244, 20];
      const deviceCount = 15;
      final devices = List.generate(deviceCount, (index) {
        final profile = index % profiles.length;
        return _Wallet(
          root,
          'Device-$index',
          name: '${profiles[profile]} ${index + 1}',
          packetSize: packetSizes[profile],
        );
      });
      String codeFor(int index) => 'TEST-${index + 1}';
      final expected = {
        'SHARED',
        for (var i = 0; i < deviceCount; i++) codeFor(i),
      };
      final photoBytes = _largePng();
      final photo = await File(
        '${root.path}/original.png',
      ).writeAsBytes(photoBytes);
      final localCopies = <LoyaltyCard>[];
      for (var index = 0; index < devices.length; index++) {
        final device = devices[index];
        localCopies.add(
          await device.store.save(
            name: 'Shared card on ${device.peer.name}',
            note: 'Local note $index',
            code: 'SHARED',
            photo: null,
          ),
        );
        await device.store.save(
          name: 'Card from ${device.peer.name}',
          code: codeFor(index),
          photo: index == 0 || index == 14 ? photo : null,
        );
      }
      await photo.delete();

      final interrupted = await _syncOverPackets(
        devices[0],
        devices[1],
        disconnectAfterBytes: 12 * 1024,
      );
      expect(_counts(interrupted.$1), (0, 0, true));
      expect(_counts(interrupted.$2), (0, 0, true));
      expect(
        (await devices[1].store.load()).map((card) => card.code),
        unorderedEquals(['SHARED', codeFor(1)]),
      );
      _expectPair(
        await _syncOverPackets(devices[0], devices[1]),
        sent: 1,
        received: 1,
      );

      Future<List<_Pair>> tick(List<int?> positions) => Future.wait([
        for (var a = 0; a < devices.length; a++)
          for (var b = a + 1; b < devices.length; b++)
            if (positions[a] != null &&
                positions[b] != null &&
                (positions[a]! - positions[b]!).abs() <= 1)
              _syncOverPackets(devices[a], devices[b]),
      ]);

      Future<List<Set<String?>>> inventories() async {
        final wallets = await Future.wait(
          devices.map((device) => device.store.load()),
        );
        final result = <Set<String?>>[];
        for (var i = 0; i < wallets.length; i++) {
          final cards = wallets[i];
          final codes = cards.map((card) => card.code).toSet();
          expect(codes, hasLength(cards.length), reason: devices[i].peer.name);
          final local = cards.singleWhere((card) => card.code == 'SHARED');
          expect(local.id, localCopies[i].id);
          expect(local.name, localCopies[i].name);
          expect(local.note, localCopies[i].note);
          result.add(codes);
        }
        return result;
      }

      Future<void> checkContacts(List<int?> positions) async {
        for (final (left, right) in await tick(positions)) {
          expect(left?.incomplete, isFalse);
          expect(right?.incomplete, isFalse);
          expect(left?.sent, right?.received);
          expect(right?.sent, left?.received);
        }
      }

      // Three separated groups exchange with neighbors. The last tablet
      // starts outside every group's reach.
      final partitions = List<int?>.generate(
        deviceCount,
        (index) => index == 14 ? null : (index ~/ 5) * 10 + index % 5,
      );
      for (var round = 0; round < 4; round++) {
        await checkContacts(partitions);
      }
      var previous = await inventories();
      for (var i = 0; i < 14; i++) {
        expect(previous[i], {
          'SHARED',
          for (var j = (i ~/ 5) * 5; j < min((i ~/ 5 + 1) * 5, 14); j++)
            codeFor(j),
        });
      }
      expect(previous[14], {'SHARED', codeFor(14)});

      // Change the encounters reproducibly and take a different subset out of
      // range each round. Concurrent encounters can offer the same card twice.
      final movement = Random(81);
      for (var round = 0; round < 8; round++) {
        final order = List.generate(deviceCount, (index) => index)
          ..shuffle(movement);
        final positions = List<int?>.filled(deviceCount, null);
        for (var slot = 0; slot < deviceCount; slot++) {
          final index = order[slot];
          if ((index + round) % 7 != 0) {
            positions[index] = (slot ~/ 3) * 10 + slot % 3;
          }
        }
        await checkContacts(positions);
        final current = await inventories();
        for (var i = 0; i < deviceCount; i++) {
          expect(current[i].containsAll(previous[i]), isTrue);
          if (positions[i] == null) expect(current[i], previous[i]);
        }
        previous = current;
      }

      // A chain of encounters eventually delivers every card, even though
      // its endpoints can never connect directly.
      final chain = List.generate(deviceCount, (index) => index);
      for (var round = 0; round < deviceCount - 1; round++) {
        if (previous.every((codes) => codes.length == expected.length)) break;
        await checkContacts(chain);
        previous = await inventories();
      }
      for (final device in devices) {
        final cards = await device.store.load();
        expect(cards.map((card) => card.code), unorderedEquals(expected));
        for (final index in [0, 14]) {
          final card = cards.singleWhere((card) => card.code == codeFor(index));
          expect(await File(card.photoPath!).readAsBytes(), photoBytes);
        }
      }
      final crowded = await tick(List.filled(deviceCount, 0));
      expect(crowded, hasLength(deviceCount * (deviceCount - 1) ~/ 2));
      for (final result in crowded) {
        _expectPair(result, sent: 0, received: 0);
      }
    },
  );

  test('different groups do not learn identities or open a sync', () async {
    final a = _Wallet(root, 'Alpha');
    final b = _Wallet(root, 'Beta');
    await a.store.save(name: 'Private card', photo: null, code: '0007');

    final result = await _connect(
      (link) => a.run(link, groupKey: _groupKey),
      (link) => b.run(link, groupKey: _otherKey),
    );

    expect(result, (null, null));
    expect(a.peers, isEmpty);
    expect(b.peers, isEmpty);
    expect(await b.store.load(), isEmpty);
  });

  test('joins only after approval and persists before transferring', () async {
    final inviter = _Wallet(root, 'Inviter');
    final joiner = _Wallet(root, 'Joiner');
    await inviter.store.save(name: 'Market', photo: null, code: '007');
    await joiner.store.save(name: 'Bookshop', photo: null, code: '008');
    Uint8List? savedKey;
    final events = <String>[];

    final result = await _connect(
      (link) => joiner.run(
        link,
        joinKey: _inviteKey,
        onJoined: (key, peer) async {
          expect(peer.id, inviter.peer.id);
          expect(await joiner.store.load(), hasLength(1));
          savedKey = Uint8List.fromList(key);
          events.add('saved');
        },
        onPeer: (_) => events.add('peer'),
      ),
      (link) => inviter.run(
        link,
        groupKey: _groupKey,
        inviteKey: _inviteKey,
        acceptInvite: (peer) async {
          expect(peer.id, joiner.peer.id);
          expect(inviter.peers, isEmpty);
          events.add('approved');
          return _groupKey;
        },
      ),
    );

    expect(events, ['approved', 'saved', 'peer']);
    expect(savedKey, _groupKey);
    _expectPair(result, sent: 1, received: 1);
    _expectPair(
      await _connect(
        (link) => inviter.run(link, groupKey: _groupKey),
        (link) => joiner.run(link, groupKey: savedKey),
      ),
      sent: 0,
      received: 0,
    );
  });

  test('a rejection and replay cannot join the group', () async {
    final inviter = _Wallet(root, 'Inviter');
    final joiner = _Wallet(root, 'Joiner');
    var approvals = 0;
    var joins = 0;
    Uint8List? oldIdentity;

    Future<BluetoothSyncResult?> host(BluetoothSyncLink link) => inviter.run(
      link,
      groupKey: _groupKey,
      inviteKey: _inviteKey,
      acceptInvite: (_) async {
        approvals++;
        return null;
      },
    );
    Future<BluetoothSyncResult?> guest(BluetoothSyncLink link) => joiner.run(
      link,
      joinKey: _inviteKey,
      onJoined: (_, _) async {
        joins++;
      },
    );
    final rejected = await _connect(
      guest,
      host,
      centralFrame: (index, frame) {
        if (index == 1) oldIdentity = Uint8List.fromList(frame);
        return frame;
      },
    );
    expect(rejected, (null, null));
    expect(approvals, 1);
    expect(oldIdentity, isNotNull);

    final replayed = await _connect(
      guest,
      host,
      centralFrame: (index, frame) => index == 1 ? oldIdentity! : frame,
    );
    expect(replayed, (null, null));
    expect(approvals, 1);
    expect(joins, 0);
    expect(inviter.peers, isEmpty);
    expect(joiner.peers, isEmpty);
  });

  test(
    'an interrupted receipt keeps the imported card and retries safely',
    () async {
      final a = _Wallet(root, 'Alpha');
      final b = _Wallet(root, 'Beta');
      await a.store.save(name: 'Market', photo: null, code: '007');
      final interrupted = await _connect(
        (link) => a.run(link, groupKey: _groupKey),
        (link) => b.run(link, groupKey: _groupKey),
        peripheralFrame: (index, frame) {
          // The empty receiver sends hello, identity, and manifest before the receipt.
          if (index == 3) throw StateError('Lost Bluetooth connection');
          return frame;
        },
      );

      expect(_counts(interrupted.$1), (0, 0, true));
      expect(_counts(interrupted.$2), (0, 1, true));
      expect((await b.store.load()).single.code, '007');
      _expectPair(await _sync(a, b), sent: 0, received: 0);
      expect(await b.store.load(), hasLength(1));
    },
  );
}

class _Wallet {
  _Wallet(Directory root, String id, {String? name, this.packetSize = 512})
    : peer = BluetoothSyncPeer(id: id, name: name ?? 'Wallet $id'),
      store = CardStore(Directory('${root.path}/$id'));

  final BluetoothSyncPeer peer;
  final CardStore store;
  final int packetSize;
  final peers = <BluetoothSyncPeer>[];

  Future<BluetoothSyncResult?> run(
    BluetoothSyncLink link, {
    Uint8List? groupKey,
    Uint8List? inviteKey,
    Uint8List? joinKey,
    Future<Uint8List?> Function(BluetoothSyncPeer)? acceptInvite,
    Future<void> Function(Uint8List, BluetoothSyncPeer)? onJoined,
    void Function(BluetoothSyncPeer)? onPeer,
  }) => runBluetoothSyncSession(
    link: link,
    store: store,
    local: peer,
    groupKey: groupKey,
    inviteKey: inviteKey,
    joinKey: joinKey,
    acceptInvite: acceptInvite,
    onJoined: onJoined,
    onPeer: (peer) {
      peers.add(peer);
      onPeer?.call(peer);
    },
  );
}

typedef _Pair = (BluetoothSyncResult?, BluetoothSyncResult?);
typedef _Run = Future<BluetoothSyncResult?> Function(BluetoothSyncLink);
typedef _FrameHook = Uint8List Function(int index, Uint8List frame);

Future<_Pair> _sync(_Wallet central, _Wallet peripheral) => _connect(
  (link) => central.run(link, groupKey: _groupKey),
  (link) => peripheral.run(link, groupKey: _groupKey),
);

Future<_Pair> _syncOverPackets(
  _Wallet central,
  _Wallet peripheral, {
  int? disconnectAfterBytes,
}) async {
  late final BluetoothPacketLink left;
  late final BluetoothPacketLink right;
  var centralBytes = 0;
  left = BluetoothPacketLink(
    central: true,
    maxPacketBytes: central.packetSize,
    sendPacket: (packet) async {
      centralBytes += packet.length;
      if (disconnectAfterBytes != null && centralBytes > disconnectAfterBytes) {
        left.endInput();
        right.endInput();
        throw StateError('Devices moved out of range');
      }
      if (!right.addPacket(packet)) throw StateError('Peripheral disconnected');
    },
  );
  right = BluetoothPacketLink(
    central: false,
    maxPacketBytes: peripheral.packetSize,
    sendPacket: (packet) async {
      if (!left.addPacket(packet)) throw StateError('Central disconnected');
    },
  );
  Future<BluetoothSyncResult?> run(
    _Wallet wallet,
    BluetoothPacketLink link,
    BluetoothPacketLink remote,
  ) async {
    try {
      return await wallet.run(link, groupKey: _groupKey);
    } finally {
      remote.endInput();
    }
  }

  try {
    final results = await Future.wait([
      run(central, left, right),
      run(peripheral, right, left),
    ]).timeout(const Duration(seconds: 10));
    return (results[0], results[1]);
  } finally {
    left.close();
    right.close();
  }
}

Future<_Pair> _connect(
  _Run central,
  _Run peripheral, {
  _FrameHook? centralFrame,
  _FrameHook? peripheralFrame,
}) async {
  final toCentral = _Pipe();
  final toPeripheral = _Pipe();
  Future<BluetoothSyncResult?> run(_Run session, _MemoryLink link) async {
    try {
      return await session(link);
    } finally {
      link.outgoing.close();
    }
  }

  final results = await Future.wait([
    run(central, _MemoryLink(true, toCentral, toPeripheral, centralFrame)),
    run(
      peripheral,
      _MemoryLink(false, toPeripheral, toCentral, peripheralFrame),
    ),
  ]).timeout(const Duration(seconds: 5));
  return (results[0], results[1]);
}

(int, int, bool)? _counts(BluetoothSyncResult? result) =>
    result == null ? null : (result.sent, result.received, result.incomplete);

void _expectPair(_Pair pair, {required int sent, required int received}) {
  expect(_counts(pair.$1), (sent, received, false));
  expect(_counts(pair.$2), (received, sent, false));
}

class _MemoryLink implements BluetoothSyncLink {
  _MemoryLink(this.central, this.incoming, this.outgoing, this.hook);

  @override
  final bool central;
  final _Pipe incoming;
  final _Pipe outgoing;
  final _FrameHook? hook;
  int _sent = 0;

  @override
  Future<void> send(Uint8List frame) async {
    expect(frame.length, lessThanOrEqualTo(maxBluetoothSyncFrameBytes));
    final index = _sent++;
    outgoing.add(hook?.call(index, frame) ?? frame);
  }

  @override
  Future<Uint8List> receive() => incoming.take();
}

class _Pipe {
  final _queue = Queue<Uint8List>();
  Completer<void>? _wake;
  bool _closed = false;

  void add(Uint8List frame) {
    if (_closed) throw StateError('Bluetooth connection closed');
    _queue.add(Uint8List.fromList(frame));
    _signal();
  }

  void close() {
    _closed = true;
    _signal();
  }

  void _signal() {
    _wake?.complete();
    _wake = null;
  }

  Future<Uint8List> take() async {
    while (_queue.isEmpty) {
      if (_closed) throw StateError('Bluetooth connection closed');
      await (_wake ??= Completer<void>()).future;
    }
    return _queue.removeFirst();
  }
}

Uint8List _largePng() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVdQAAAAASUVORK5CYII=',
  );
  final text = Uint8List.fromList([
    ...ascii.encode('tEXtComment'),
    0,
    ...List.filled(40 * 1024, 65),
  ]);
  var crc = 0xffffffff;
  for (final byte in text) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ (crc.isOdd ? 0xedb88320 : 0);
    }
  }
  Uint8List uint32(int value) =>
      (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
  return Uint8List.fromList([
    ...png.take(png.length - 12),
    ...uint32(text.length - 4),
    ...text,
    ...uint32(crc ^ 0xffffffff),
    ...png.skip(png.length - 12),
  ]);
}
