import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/card_store.dart';
import 'package:loyalty_pocket/nearby_merge.dart';
import 'package:loyalty_pocket/nearby_transport.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('loyalty-merge-');
    addTearDown(() => root.delete(recursive: true));
  });

  test('merges three wallets without duplicates or local changes', () async {
    final hub = CardStore(Directory('${root.path}/hub'));
    final left = CardStore(Directory('${root.path}/left'));
    final right = CardStore(Directory('${root.path}/right'));
    for (final (store, note, name, code) in [
      (hub, 'Hub note', 'Groceries', '101'),
      (left, 'Left note', 'Bookshop', '202'),
      (right, 'Right note', 'Stationery', '303'),
    ]) {
      await store.save(name: 'Coffee', photo: null, code: '100', note: note);
      await store.save(name: name, photo: null, code: code);
    }
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVdQAAAAASUVORK5CYII=',
    );
    final photo = await File('${root.path}/original.png').writeAsBytes(png);
    final hubPhoto = await hub.save(
      name: 'Market photo',
      photo: photo,
      code: null,
      note: 'Hub photo note',
    );
    final leftPhoto = await left.save(
      name: 'Market photo',
      photo: photo,
      code: null,
      note: 'Left photo note',
    );
    await photo.delete();
    final peers = [
      await _startPeer(left, 'Left'),
      await _startPeer(right, 'Right'),
    ];

    final result = await _merge(hub, peers);
    final repeated = await _merge(hub, peers);

    expect(result, (sent: 5, received: 2, connected: true, incomplete: false));
    expect(repeated, (
      sent: 0,
      received: 0,
      connected: true,
      incomplete: false,
    ));
    expect(leftPhoto.id, isNot(hubPhoto.id));
    for (final (store, note, expectedPhoto) in [
      (hub, 'Hub note', hubPhoto),
      (left, 'Left note', leftPhoto),
      (right, 'Right note', hubPhoto),
    ]) {
      final cards = await store.load();
      expect(
        cards.map((card) => card.name),
        unorderedEquals([
          'Coffee',
          'Groceries',
          'Bookshop',
          'Stationery',
          'Market photo',
        ]),
      );
      expect((await store.findDuplicate('100', null))?.note, note);
      final savedPhoto = cards.singleWhere((card) => card.code == null);
      expect(savedPhoto.id, expectedPhoto.id);
      expect(savedPhoto.note, expectedPhoto.note);
      expect(await File(savedPhoto.photoPath!).readAsBytes(), png);
    }
  });

  test('continues a group merge after one card fails to import', () async {
    final hub = _RejectFirstImportStore(Directory('${root.path}/hub'));
    final left = CardStore(Directory('${root.path}/left'));
    final right = CardStore(Directory('${root.path}/right'));
    await left.save(name: 'Bookshop', photo: null, code: '202');
    await left.save(name: 'Groceries', photo: null, code: '203');
    await right.save(name: 'Stationery', photo: null, code: '303');
    final peers = [
      await _startPeer(left, 'Left'),
      await _startPeer(right, 'Right'),
    ];

    final result = await _merge(hub, peers);

    final healthy = (await left.load()).singleWhere(
      (card) => card.code != '303' && card.id != hub.rejectedId,
    );
    expect(result, (sent: 2, received: 2, connected: true, incomplete: true));
    expect(
      (await hub.load()).map((card) => card.name),
      unorderedEquals([healthy.name, 'Stationery']),
    );
    expect(
      (await right.load()).map((card) => card.name),
      unorderedEquals([healthy.name, 'Stationery']),
    );
  });

  test('continues a group merge after one card fails to export', () async {
    final hub = _RejectFirstExportStore(Directory('${root.path}/hub'));
    final left = CardStore(Directory('${root.path}/left'));
    final right = CardStore(Directory('${root.path}/right'));
    await hub.save(name: 'Bookshop', photo: null, code: '202');
    await hub.save(name: 'Groceries', photo: null, code: '203');
    final peers = [
      await _startPeer(left, 'Left'),
      await _startPeer(right, 'Right'),
    ];

    final result = await _merge(hub, peers);

    final healthy = (await hub.load()).singleWhere(
      (card) => card.id != hub.rejectedId,
    );
    expect(result, (sent: 3, received: 0, connected: true, incomplete: true));
    expect((await left.load()).single.id, healthy.id);
    expect(await right.load(), hasLength(2));

    final repeated = await _merge(hub, peers);

    expect(repeated, (
      sent: 1,
      received: 0,
      connected: true,
      incomplete: false,
    ));
    expect(await left.load(), hasLength(2));
    expect(await right.load(), hasLength(2));
  });

  test('continues a group merge after a peer rejects one card', () async {
    final hub = CardStore(Directory('${root.path}/hub'));
    final left = _RejectFirstImportStore(Directory('${root.path}/left'));
    final right = CardStore(Directory('${root.path}/right'));
    await hub.save(name: 'Bookshop', photo: null, code: '202');
    await hub.save(name: 'Groceries', photo: null, code: '203');
    final peers = [
      await _startPeer(left, 'Left'),
      await _startPeer(right, 'Right'),
    ];

    final result = await _merge(hub, peers);
    expect(result, (sent: 3, received: 0, connected: true, incomplete: true));
    expect((await left.load()).single.id, isNot(left.rejectedId));
    expect(await right.load(), hasLength(2));

    final repeated = await _merge(hub, peers);
    expect(repeated, (
      sent: 1,
      received: 0,
      connected: true,
      incomplete: false,
    ));
    expect(await left.load(), hasLength(2));
  });
}

Future<NearbyMergePeer> _startPeer(CardStore store, String name) async {
  final server = await NearbyMergeServer.start(
    store: store,
    name: name,
    confirm: (_, _) async => true,
    onImported: () {},
  );
  addTearDown(server.close);
  return (name: name, address: InternetAddress.loopbackIPv4, port: server.port);
}

Future<NearbyMergeResult?> _merge(
  CardStore store,
  List<NearbyMergePeer> peers,
) => NearbyMerge(
  store,
).run(peers: peers, name: 'Hub', confirm: (_, _) async => true);

class _RejectFirstImportStore extends CardStore {
  _RejectFirstImportStore(super.root);

  String? rejectedId;

  @override
  Future<bool> importForMerge(Uint8List bytes) {
    if (rejectedId == null) {
      rejectedId = (jsonDecode(utf8.decode(bytes)) as Map)['id'] as String;
      throw const FileSystemException('Could not save this card.');
    }
    return super.importForMerge(bytes);
  }
}

class _RejectFirstExportStore extends CardStore {
  _RejectFirstExportStore(super.root);

  String? rejectedId;

  @override
  Future<Uint8List?> exportForMerge(String id) {
    if (rejectedId == null) {
      rejectedId = id;
      throw const FileSystemException('Could not read this card.');
    }
    return super.exportForMerge(id);
  }
}
