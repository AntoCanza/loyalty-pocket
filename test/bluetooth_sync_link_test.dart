import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/bluetooth_sync_link.dart';
import 'package:loyalty_pocket/bluetooth_sync_protocol.dart';

void main() {
  test('reassembles a full frame at the minimum BLE packet size', () async {
    final receiver = BluetoothPacketLink(
      central: false,
      maxPacketBytes: 20,
      sendPacket: (_) async {},
    );
    final sender = BluetoothPacketLink(
      central: true,
      maxPacketBytes: 20,
      sendPacket: (packet) async {
        expect(packet.length, lessThanOrEqualTo(20));
        expect(receiver.addPacket(packet), isTrue);
      },
    );
    addTearDown(sender.close);
    addTearDown(receiver.close);

    final frame = Uint8List.fromList(
      List.generate(maxBluetoothSyncFrameBytes, (index) => index % 256),
    );
    await sender.send(frame);
    receiver.endInput();

    expect(await receiver.receive(), frame);
    await expectLater(receiver.receive(), throwsStateError);
  });

  test('rejects an oversized frame before allocating it', () async {
    final receiver = BluetoothPacketLink(
      central: false,
      maxPacketBytes: 20,
      sendPacket: (_) async {},
    );
    addTearDown(receiver.close);
    expect(receiver.addPacket(Uint8List.fromList([0xff])), isTrue);
    expect(receiver.addPacket(Uint8List.fromList([0xff])), isFalse);
  });
}
