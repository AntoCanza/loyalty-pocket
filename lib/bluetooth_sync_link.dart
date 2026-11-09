import 'dart:async';
import 'dart:typed_data';

import 'bluetooth_sync_protocol.dart';

/// Transports one length-prefixed protocol frame across acknowledged BLE packets.
class BluetoothPacketLink implements BluetoothSyncLink {
  BluetoothPacketLink({
    required this.central,
    required int maxPacketBytes,
    required Future<void> Function(Uint8List) sendPacket,
  }) : _packetSize = maxPacketBytes.clamp(20, 512),
       _sendPacket = sendPacket;

  static const _maxFrame = maxBluetoothSyncFrameBytes;
  static const _timeout = Duration(seconds: 45);

  @override
  final bool central;
  final int _packetSize;
  final Future<void> Function(Uint8List) _sendPacket;
  final _incoming = StreamController<Uint8List>();
  late final _reader = StreamIterator(_incoming.stream);
  var _remaining = 0;
  final _header = Uint8List(2);
  var _headerLength = 0;
  Uint8List? _frame;
  var _queued = 0;
  var _ended = false;
  var _closed = false;

  @override
  Future<void> send(Uint8List frame) async {
    if (frame.isEmpty || frame.length > _maxFrame) {
      throw const FormatException('Invalid Bluetooth frame length.');
    }
    final bytes = Uint8List(frame.length + 2)
      ..[0] = frame.length >> 8
      ..[1] = frame.length & 0xff
      ..setRange(2, frame.length + 2, frame);
    for (var offset = 0; offset < bytes.length; offset += _packetSize) {
      if (_ended) throw StateError('Bluetooth link closed.');
      final end = (offset + _packetSize).clamp(0, bytes.length);
      await _sendPacket(
        Uint8List.sublistView(bytes, offset, end),
      ).timeout(_timeout);
    }
  }

  @override
  Future<Uint8List> receive() async {
    if (!await _reader.moveNext().timeout(_timeout)) {
      throw StateError('Bluetooth link closed.');
    }
    final frame = _reader.current;
    _queued -= frame.length;
    return frame;
  }

  bool addPacket(Uint8List packet) {
    if (_ended || packet.isEmpty || packet.length > 512) return false;
    var offset = 0;
    while (offset < packet.length) {
      if (_frame == null) {
        while (_headerLength < 2 && offset < packet.length) {
          _header[_headerLength++] = packet[offset++];
        }
        if (_headerLength < 2) break;
        _headerLength = 0;
        _remaining = (_header[0] << 8) | _header[1];
        if (_remaining == 0 || _remaining > _maxFrame) return false;
        _frame = Uint8List(_remaining);
      }
      final frame = _frame!;
      final count = _remaining.clamp(0, packet.length - offset);
      final start = frame.length - _remaining;
      frame.setRange(start, start + count, packet, offset);
      offset += count;
      _remaining -= count;
      if (_remaining == 0) {
        _frame = null;
        _queued += frame.length;
        if (_queued > _maxFrame * 8) return false;
        _incoming.add(frame);
      }
    }
    return true;
  }

  void endInput() {
    if (_ended) return;
    _ended = true;
    unawaited(_incoming.close());
  }

  void close() {
    if (_closed) return;
    _closed = true;
    endInput();
    unawaited(_reader.cancel());
  }
}
