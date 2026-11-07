import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

  test('pairs after abandoned greetings fill the session capacity', () async {
    final root = await Directory.systemTemp.createTemp('loyalty-nearby-');
    addTearDown(() => root.delete(recursive: true));
    var approvals = 0;
    final server = await NearbyMergeServer.start(
      store: CardStore(root),
      name: 'Receiver',
      confirm: (_, _) async {
        approvals++;
        return true;
      },
      onImported: () {},
    );
    addTearDown(server.close);

    final address = InternetAddress.loopbackIPv4;
    final http = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() => http.close(force: true));
    final hello = Uri(
      scheme: 'http',
      host: address.address,
      port: server.port,
      path: '/hello',
    );
    for (var i = 0; i < 8; i++) {
      final request = await http.postUrl(hello);
      request.write(
        jsonEncode({
          'name': 'Abandoned phone',
          'commitment': base64Encode(List.filled(32, i)),
        }),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
    }
    expect(approvals, 0);

    final client = await NearbyMergeClient.connect(
      address: address,
      port: server.port,
      name: 'Sender',
      confirm: (_, _) async => true,
    );
    if (client != null) addTearDown(client.close);
    expect(client, isNotNull);
    expect(approvals, 1);
  });

  test('pairs when previously declined peers have not disconnected', () async {
    final root = await Directory.systemTemp.createTemp('loyalty-nearby-');
    addTearDown(() => root.delete(recursive: true));
    final server = await NearbyMergeServer.start(
      store: CardStore(root),
      name: 'Receiver',
      confirm: (name, _) async => name == 'Sender',
      onImported: () {},
    );
    addTearDown(server.close);

    final address = InternetAddress.loopbackIPv4;
    final dismiss = Completer<bool>();
    final declined = <Future<NearbyMergeClient?>>[];
    addTearDown(() async {
      dismiss.complete(false);
      await Future.wait(declined);
    });
    for (var i = 0; i < 8; i++) {
      final ready = Completer<void>();
      declined.add(
        NearbyMergeClient.connect(
          address: address,
          port: server.port,
          name: 'Declined phone',
          confirm: (_, _) {
            ready.complete();
            return dismiss.future;
          },
        ),
      );
      await ready.future.timeout(const Duration(seconds: 5));
    }

    final client = await NearbyMergeClient.connect(
      address: address,
      port: server.port,
      name: 'Sender',
      confirm: (_, _) async => true,
    );
    if (client != null) addTearDown(client.close);
    expect(client, isNotNull);
  });

  test('invalid key reveals do not hold pairing slots', () async {
    final root = await Directory.systemTemp.createTemp('loyalty-nearby-');
    addTearDown(() => root.delete(recursive: true));
    var approvals = 0;
    final server = await NearbyMergeServer.start(
      store: CardStore(root),
      name: 'Receiver',
      confirm: (_, _) async {
        approvals++;
        return true;
      },
      onImported: () {},
    );
    addTearDown(server.close);

    final address = InternetAddress.loopbackIPv4;
    final http = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() => http.close(force: true));
    final origin = Uri(
      scheme: 'http',
      host: address.address,
      port: server.port,
    );
    Future<HttpClientResponse> post(
      String path,
      Map<String, String> data,
    ) async {
      final request = await http.postUrl(origin.replace(path: path));
      request.write(jsonEncode(data));
      return request.close();
    }

    const name = 'Invalid phone';
    final key = List.filled(32, 0);
    final salt = List.filled(32, 1);
    final commitment = sha256.convert([...key, ...salt, ...utf8.encode(name)]);
    for (var i = 0; i < 8; i++) {
      final greeting = await post('/hello', {
        'name': name,
        'commitment': base64Encode(commitment.bytes),
      });
      expect(greeting.statusCode, HttpStatus.ok);
      final data = jsonDecode(await utf8.decoder.bind(greeting).join());
      final rejection = await post('/reveal/${data['id']}', {
        'key': base64Encode(key),
        'salt': base64Encode(salt),
      });
      expect(rejection.statusCode, HttpStatus.badRequest);
      await rejection.drain<void>();
    }
    expect(approvals, 0);

    final client = await NearbyMergeClient.connect(
      address: address,
      port: server.port,
      name: 'Sender',
      confirm: (_, _) async => true,
    );
    if (client != null) addTearDown(client.close);
    expect(client, isNotNull);
    expect(approvals, 1);
  });

  test('downloads later cards when an advertised photo disappears', () async {
    final root = await Directory.systemTemp.createTemp('loyalty-nearby-');
    addTearDown(() => root.delete(recursive: true));
    final store = CardStore(root);
    final photo = await File('${root.path}/card.gif').writeAsBytes(
      base64Decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'),
    );
    final unavailable = await store.save(name: 'With photo', photo: photo);
    final available = await store.save(
      name: 'With code',
      photo: null,
      code: '1',
    );
    final server = await NearbyMergeServer.start(
      store: store,
      name: 'Receiver',
      confirm: (_, _) async => true,
      onImported: () {},
    );
    addTearDown(server.close);
    final client = (await NearbyMergeClient.connect(
      address: InternetAddress.loopbackIPv4,
      port: server.port,
      name: 'Sender',
      confirm: (_, _) async => true,
    ))!;
    addTearDown(client.close);

    expect(
      (await client.manifest()).map((card) => card.id),
      unorderedEquals([unavailable.id, available.id]),
    );
    await File(unavailable.photoPath!).delete();
    expect(await client.downloadCard(unavailable.id), isNull);
    expect(await client.downloadCard(available.id), isNotNull);
  });

  test('uploads later cards when the receiver rejects one card', () async {
    final root = await Directory.systemTemp.createTemp('loyalty-nearby-');
    addTearDown(() => root.delete(recursive: true));
    final source = CardStore(Directory('${root.path}/source'));
    final destination = CardStore(Directory('${root.path}/destination'));
    final available = await source.save(
      name: 'With code',
      photo: null,
      code: '1',
    );
    var imported = 0;
    final server = await NearbyMergeServer.start(
      store: destination,
      name: 'Receiver',
      confirm: (_, _) async => true,
      onImported: () => imported++,
    );
    addTearDown(server.close);
    final client = (await NearbyMergeClient.connect(
      address: InternetAddress.loopbackIPv4,
      port: server.port,
      name: 'Sender',
      confirm: (_, _) async => true,
    ))!;
    addTearDown(client.close);

    await expectLater(
      client.sendCard(utf8.encode('{')),
      throwsA(isA<NearbyCardTransferException>()),
    );
    expect(
      await client.sendCard((await source.exportForMerge(available.id))!),
      isTrue,
    );
    expect((await destination.load()).single.id, available.id);
    expect(imported, 1);
  });
}
