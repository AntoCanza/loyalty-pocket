import 'dart:io';
import 'dart:typed_data';

import 'card_store.dart';
import 'nearby_transport.dart';

typedef NearbyMergePeer = ({String name, InternetAddress address, int port});
typedef NearbyMergeResult = ({
  int sent,
  int received,
  bool connected,
  bool incomplete,
});

class NearbyMerge {
  NearbyMerge(this._store);

  final CardStore _store;
  final _clients = <NearbyMergeClient>{};
  bool _canceled = false;

  Future<NearbyMergeResult?> run({
    required Iterable<NearbyMergePeer> peers,
    required String name,
    required NearbyConfirmation confirm,
  }) async {
    final sessions = <NearbyMergeClient>[];
    var received = 0;
    var sent = 0;
    var incomplete = false;
    try {
      final localKeys = _keys(await _store.mergeManifest());
      for (final peer in peers) {
        if (_canceled) return null;
        try {
          final client = await NearbyMergeClient.connect(
            address: peer.address,
            port: peer.port,
            name: name,
            confirm: confirm,
          );
          if (client == null) {
            incomplete = true;
            continue;
          }
          if (_canceled) {
            await client.close();
            return null;
          }
          _clients.add(client);
          final manifest = await client.manifest();
          sessions.add(client);
          for (final card in manifest) {
            if (_canceled) return null;
            if (card.keys.any(localKeys.contains)) continue;
            final data = await client.downloadCard(card.id);
            if (_canceled) return null;
            if (data == null) {
              incomplete = true;
              continue;
            }
            try {
              if (await _store.importForMerge(data)) {
                received++;
                localKeys.addAll(card.keys);
              }
            } on Exception {
              incomplete = true;
            }
          }
        } catch (_) {
          incomplete = true;
        }
      }

      if (_canceled) return null;
      final union = await _store.mergeManifest();
      for (final client in sessions) {
        if (_canceled) return null;
        try {
          final remoteKeys = _keys(await client.manifest());
          for (final card in union) {
            if (_canceled) return null;
            if (card.keys.any(remoteKeys.contains)) continue;
            final Uint8List? data;
            try {
              data = await _store.exportForMerge(card.id);
            } on Exception {
              incomplete = true;
              continue;
            }
            if (_canceled) return null;
            if (data == null) {
              incomplete = true;
              continue;
            }
            try {
              if (await client.sendCard(data)) sent++;
              remoteKeys.addAll(card.keys);
            } on NearbyCardTransferException {
              incomplete = true;
            }
          }
        } catch (_) {
          incomplete = true;
        }
      }
    } catch (_) {
      incomplete = true;
    } finally {
      await _closeClients();
    }

    if (_canceled) return null;
    return (
      sent: sent,
      received: received,
      connected: sessions.isNotEmpty,
      incomplete: incomplete,
    );
  }

  Future<void> cancel() {
    _canceled = true;
    return _closeClients();
  }

  Future<void> _closeClients() {
    final clients = _clients.toList();
    _clients.clear();
    return Future.wait(clients.map((client) => client.close()));
  }

  Set<String> _keys(List<MergeCardRef> manifest) => {
    for (final card in manifest) ...card.keys,
  };
}
