import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/card_store.dart';
import 'package:loyalty_pocket/nearby_transport.dart';

void main() {
  test('pairs and transfers missing cards in both directions', () async {
    final root = await Directory.systemTemp.createTemp('loyalty-nearby-');
    addTearDown(() => root.delete(recursive: true));
    final left = CardStore(Directory('${root.path}/left'));
    final right = CardStore(Directory('${root.path}/right'));
    await left.save(
      name: 'Coffee',
      photo: null,
      code: '000321',
      format: CardCodeFormat.code128,
      note: 'Left note',
    );
    final leftOnly = await left.save(
      name: 'Groceries',
      photo: null,
      code: '000654',
    );
    final rightCommon = await right.save(
      name: 'Coffee',
      photo: null,
      code: '000321',
      format: CardCodeFormat.qr,
      note: 'Right note',
    );
    final rightOnly = await right.save(
      name: 'Bookshop',
      photo: null,
      code: '000987',
    );

    var received = 0;
    final rightCode = Completer<String>();
    final leftCode = Completer<String>();
    final approveRight = Completer<bool>();
    final server = await NearbyMergeServer.start(
      store: right,
      name: 'Right phone',
      confirm: (name, code) {
        expect(name, 'Left phone');
        rightCode.complete(code);
        return approveRight.future;
      },
      onImported: () => received++,
    );
    addTearDown(server.close);
    var paired = false;
    final pairing =
        NearbyMergeClient.connect(
          address: InternetAddress.loopbackIPv4,
          port: server.port,
          name: 'Left phone',
          confirm: (name, code) async {
            expect(name, 'Right phone');
            leftCode.complete(code);
            return true;
          },
        ).then((client) {
          paired = true;
          return client;
        });

    final code = await leftCode.future.timeout(const Duration(seconds: 5));
    expect(code, matches(r'^[0-9]{6}$'));
    expect(code, await rightCode.future);
    expect(paired, isFalse);
    approveRight.complete(true);

    final client = (await pairing)!;
    addTearDown(client.close);
    final manifest = await client.manifest();
    expect(manifest.map((card) => card.id), contains(rightOnly.id));
    expect(await client.downloadCard(leftOnly.id), isNull);
    expect(
      await left.importForMerge((await client.downloadCard(rightCommon.id))!),
      isFalse,
    );
    expect(
      await left.importForMerge((await client.downloadCard(rightOnly.id))!),
      isTrue,
    );
    final leftFile = (await left.exportForMerge(leftOnly.id))!;
    expect(await client.sendCard(leftFile), isTrue);
    expect(await client.sendCard(leftFile), isFalse);
    expect(received, 1);
    expect(
      (await left.load()).map((card) => card.name),
      unorderedEquals(['Coffee', 'Groceries', 'Bookshop']),
    );
    expect(
      (await right.load()).map((card) => card.name),
      unorderedEquals(['Coffee', 'Groceries', 'Bookshop']),
    );
    expect((await left.findDuplicate('000321', null))?.note, 'Left note');
    expect((await right.findDuplicate('000321', null))?.note, 'Right note');
  });

  test(
    'does not establish a session when the receiving device declines',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'loyalty-nearby-denied-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = CardStore(root);
      var received = 0;
      final server = await NearbyMergeServer.start(
        store: store,
        name: 'Receiver',
        confirm: (_, _) async => false,
        onImported: () => received++,
      );
      addTearDown(server.close);

      final client = await NearbyMergeClient.connect(
        address: InternetAddress.loopbackIPv4,
        port: server.port,
        name: 'Sender',
        confirm: (_, _) async => true,
      );
      expect(client, isNull);
      expect(received, 0);
      expect(await store.load(), isEmpty);
    },
  );
}
