import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/bluetooth_sync_protocol.dart';
import 'package:loyalty_pocket/card_store.dart';
import 'package:loyalty_pocket/wifi_sync_transport.dart';

void main() {
  test('reads fragmented and consecutive frames over TCP', () async {
    final (sender, receiver) = await _loopback();
    final link = WifiSyncLink(receiver, central: false);
    addTearDown(sender.destroy);
    addTearDown(link.close);

    final first = link.receive();
    sender.add([0]);
    await sender.flush();
    sender.add([3, 1]);
    await sender.flush();
    sender.add([2, 3, 0, 2, 4, 5]);
    await sender.flush();
    expect(await first, [1, 2, 3]);
    expect(await link.receive(), [4, 5]);

    final returned = WifiSyncLink(sender, central: true);
    // The raw sender was only used for writing and has no competing listener.
    addTearDown(returned.close);
    final largest = Uint8List.fromList(
      List.generate(maxBluetoothSyncFrameBytes, (index) => index % 256),
    );
    await link.send(largest);
    expect(await returned.receive(), largest);
  });

  test('rejects an oversized frame and closes its socket once', () async {
    final (sender, receiver) = await _loopback();
    var closed = 0;
    final link = WifiSyncLink(
      receiver,
      central: false,
      onClosed: () {
        closed++;
      },
    );
    addTearDown(sender.destroy);
    addTearDown(link.close);
    final length = maxBluetoothSyncFrameBytes + 1;
    final read = expectLater(link.receive(), throwsFormatException);
    sender.add([length >> 8, length & 0xff]);
    await sender.flush();
    await read;
    await expectLater(link.receive(), throwsStateError);
    link.close();
    expect(closed, 1);
  });

  test('closing a link releases a read waiting for socket data', () async {
    final (sender, receiver) = await _loopback();
    final link = WifiSyncLink(receiver, central: false);
    addTearDown(sender.destroy);
    addTearDown(link.close);
    final read = expectLater(link.receive(), throwsStateError);
    link.close();
    await read.timeout(const Duration(seconds: 3));
  });

  test(
    'runs encrypted additive wallet sync through a TCP connection',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'loyalty-wifi-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final left = CardStore(Directory('${directory.path}/left'));
      final right = CardStore(Directory('${directory.path}/right'));
      await left.save(name: 'Market', photo: null, code: '007');
      await left.save(
        name: 'Local Coffee',
        note: 'Left note',
        photo: null,
        code: '004',
      );
      await right.save(name: 'Bookshop', photo: null, code: '008');
      await right.save(
        name: 'Other Coffee',
        note: 'Right note',
        photo: null,
        code: '004',
      );
      final key = Uint8List.fromList(List.filled(32, 27));
      final (client, server) = await _loopback();
      final central = WifiSyncLink(client, central: true);
      final peripheral = WifiSyncLink(server, central: false);
      addTearDown(central.close);
      addTearDown(peripheral.close);

      Future<BluetoothSyncResult?> run(
        WifiSyncLink link,
        CardStore store,
        String identity,
      ) async {
        try {
          return await runBluetoothSyncSession(
            link: link,
            store: store,
            local: BluetoothSyncPeer(id: identity, name: identity),
            groupKey: key,
            onPeer: (_) {},
          );
        } finally {
          link.close();
        }
      }

      final results = await Future.wait([
        run(central, left, 'Left'),
        run(peripheral, right, 'Right'),
      ]).timeout(const Duration(seconds: 5));

      for (final result in results) {
        expect(result?.sent, 1);
        expect(result?.received, 1);
        expect(result?.incomplete, isFalse);
      }
      for (final (store, note) in [
        (left, 'Left note'),
        (right, 'Right note'),
      ]) {
        final cards = await store.load();
        expect(
          cards.map((card) => card.code),
          unorderedEquals(['004', '007', '008']),
        );
        expect(cards.singleWhere((card) => card.code == '004').note, note);
      }
    },
  );
}

Future<(Socket, Socket)> _loopback() async {
  final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final incoming = listener.first;
    final outgoing = await Socket.connect(
      InternetAddress.loopbackIPv4,
      listener.port,
      timeout: const Duration(seconds: 3),
    );
    return (outgoing, await incoming);
  } finally {
    await listener.close();
  }
}
