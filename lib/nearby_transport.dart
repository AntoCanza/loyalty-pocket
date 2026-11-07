import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'card_store.dart';

typedef NearbyConfirmation = Future<bool> Function(String name, String code);

class NearbyMergeException implements Exception {
  const NearbyMergeException();
}

/// The peer rejected one card and kept the session open.
class NearbyCardTransferException extends NearbyMergeException {
  const NearbyCardTransferException();
}

const _protocol = 'loyalty-pocket-merge/1';
const _pairTimeout = Duration(minutes: 2);
const _requestTimeout = Duration(seconds: 45);
const _maxManifest = 2 * 1024 * 1024;
const _maxCard = 28 * 1024 * 1024;
const _maxHandshake = 1024;
const _maxSessions = 8;
const _frameOverhead = 8 + 16;
final _random = Random.secure();
final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _sha = Sha256();
final _cardId = RegExp(r'^[a-f0-9]{48}$');
final _key = RegExp(r'^[a-f0-9]{64}$');
final _sessionId = RegExp(r'^[a-f0-9]{32}$');
final _unsafeName = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]',
);

class NearbyMergeServer {
  NearbyMergeServer._(
    this._http,
    this._store,
    this._name,
    this._confirm,
    this._onImported,
  ) {
    _http.listen(_handle);
    _sweep = Timer.periodic(const Duration(seconds: 15), (_) => _expire());
  }

  static Future<NearbyMergeServer> start({
    required CardStore store,
    required String name,
    required NearbyConfirmation confirm,
    required void Function() onImported,
  }) async {
    final localName = _readName(name);
    final HttpServer http;
    try {
      http = await HttpServer.bind(InternetAddress.anyIPv6, 0, v6Only: false);
    } on SocketException {
      final ipv4 = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      return NearbyMergeServer._(ipv4, store, localName, confirm, onImported);
    }
    return NearbyMergeServer._(http, store, localName, confirm, onImported);
  }

  final HttpServer _http;
  final CardStore _store;
  final String _name;
  final NearbyConfirmation _confirm;
  final void Function() _onImported;
  final _sessions = <String, _Session>{};
  late final Timer _sweep;
  int _requests = 0;
  int _pairing = 0;
  bool _closed = false;

  int get port => _http.port;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _sweep.cancel();
    _sessions.clear();
    await _http.close(force: true);
  }

  void _expire() {
    final now = DateTime.now();
    _sessions.removeWhere((_, session) => session.expired(now));
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    _requests++;
    try {
      if (_closed || _requests > 16) {
        throw const _HttpFailure(HttpStatus.serviceUnavailable);
      }
      final address = request.connectionInfo?.remoteAddress;
      if (address == null || !_localAddress(address)) {
        throw const _HttpFailure(HttpStatus.forbidden);
      }
      if (request.method != 'POST' || request.uri.hasQuery) {
        throw const _HttpFailure(HttpStatus.notFound);
      }
      final parts = request.uri.pathSegments;
      final result = switch (parts) {
        ['hello'] => await _hello(request),
        ['reveal', final id] => await _reveal(request, id),
        ['session', final id, final operation] => await _command(
          request,
          id,
          operation,
        ),
        _ => throw const _HttpFailure(HttpStatus.notFound),
      };
      response.headers.contentType = parts.first == 'hello'
          ? ContentType.json
          : ContentType.binary;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.contentLength = result.length;
      response.add(result);
    } on _HttpFailure catch (error) {
      response.statusCode = error.status;
      response.persistentConnection = false;
    } on TimeoutException {
      response.statusCode = HttpStatus.requestTimeout;
      response.persistentConnection = false;
    } on FormatException {
      response.statusCode = HttpStatus.badRequest;
      response.persistentConnection = false;
    } on SecretBoxAuthenticationError {
      response.statusCode = HttpStatus.forbidden;
      response.persistentConnection = false;
    } on Object {
      response.statusCode = HttpStatus.internalServerError;
      response.persistentConnection = false;
    } finally {
      _requests--;
      try {
        await response.close();
      } on Object {
        // The peer may have disconnected before receiving the response.
      }
    }
  }

  Future<List<int>> _hello(HttpRequest request) async {
    final data = _readJson(await _read(request, _maxHandshake));
    final name = _readName(data['name']);
    final commitment = _readBase64(data['commitment'], 32);
    _expire();
    if (_sessions.length + _pairing >= _maxSessions) {
      // A greeting awaiting a key or a declined pairing can be replaced.
      final abandoned = _sessions.entries
          .where(
            (entry) =>
                entry.value.pair != null || entry.value.approval == false,
          )
          .firstOrNull;
      if (abandoned == null) {
        throw const _HttpFailure(HttpStatus.serviceUnavailable);
      }
      _sessions.remove(abandoned.key);
    }
    _pairing++;
    try {
      final pair = await _x25519.newKeyPair();
      final publicKey = (await pair.extractPublicKey()).bytes;
      final id = _randomBytes(
        16,
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      if (_closed) throw const _HttpFailure(HttpStatus.serviceUnavailable);
      _sessions[id] = _Session(name, commitment, pair, publicKey);
      return utf8.encode(
        jsonEncode({'id': id, 'name': _name, 'key': base64Encode(publicKey)}),
      );
    } finally {
      _pairing--;
    }
  }

  Future<List<int>> _reveal(HttpRequest request, String id) async {
    final session = _getSession(id);
    final data = _readJson(await _read(request, _maxHandshake));
    final key = _readBase64(data['key'], 32);
    final salt = _readBase64(data['salt'], 32);
    final pair = session.pair;
    if (pair == null || _sessions[id] != session) {
      throw const _HttpFailure(HttpStatus.forbidden);
    }
    session.pair = null;
    try {
      if (!_sameBytes(
        await _commit(key, salt, session.name),
        session.commitment,
      )) {
        throw const _HttpFailure(HttpStatus.forbidden);
      }
      final secrets = await _derive(
        pair: pair,
        peerKey: key,
        clientKey: key,
        serverKey: session.publicKey,
        id: id,
        clientName: session.name,
        serverName: _name,
        salt: salt,
      );
      if (_sessions[id] != session) {
        throw const _HttpFailure(HttpStatus.forbidden);
      }
      session.secrets = secrets;
      unawaited(_approve(session, secrets.code));
      return const [];
    } finally {
      if (session.secrets == null && _sessions[id] == session) {
        _sessions.remove(id);
      }
    }
  }

  Future<void> _approve(_Session session, String code) async {
    try {
      session.approval = await _confirm(
        session.name,
        code,
      ).timeout(_pairTimeout);
    } on Object {
      session.approval = false;
    }
    session.lastUsed = DateTime.now();
  }

  Future<List<int>> _command(
    HttpRequest request,
    String id,
    String operation,
  ) async {
    final limit = switch (operation) {
      'status' || 'manifest' || 'close' => 0,
      'read' => 48,
      'write' => _maxCard,
      _ => throw const _HttpFailure(HttpStatus.notFound),
    };
    final session = _getSession(id);
    final secrets = session.secrets;
    if (secrets == null || session.busy) {
      throw const _HttpFailure(HttpStatus.forbidden);
    }
    session.busy = true;
    try {
      final frame = await _read(request, limit + _frameOverhead);
      final sequence = session.sequence;
      final clear = await _open(
        frame,
        secrets.client,
        id,
        operation,
        sequence,
        response: false,
      );
      if (_closed || _sessions[id] != session) {
        throw const _HttpFailure(HttpStatus.forbidden);
      }
      session.sequence++;
      session.lastUsed = DateTime.now();
      final result = switch (operation) {
        'status' => [
          switch (session.approval) {
            null => 0,
            true => 1,
            false => 2,
          },
        ],
        'close' => _endSession(id),
        _ when session.approval != true => throw const _HttpFailure(
          HttpStatus.forbidden,
        ),
        'manifest' => _encodeManifest(await _store.mergeManifest()),
        'read' => await _download(clear),
        'write' => await _receive(clear),
        _ => throw const _HttpFailure(HttpStatus.notFound),
      };
      return _seal(
        result,
        secrets.server,
        id,
        operation,
        sequence,
        response: true,
      );
    } finally {
      session.busy = false;
    }
  }

  _Session _getSession(String id) {
    if (!_sessionId.hasMatch(id)) {
      throw const _HttpFailure(HttpStatus.notFound);
    }
    final session = _sessions[id];
    if (session == null || session.expired(DateTime.now())) {
      _sessions.remove(id);
      throw const _HttpFailure(HttpStatus.notFound);
    }
    return session;
  }

  List<int> _endSession(String id) {
    _sessions.remove(id);
    return const [];
  }

  Future<List<int>> _download(List<int> bytes) async {
    final id = utf8.decode(bytes);
    if (!_cardId.hasMatch(id)) {
      throw const FormatException();
    }
    try {
      final card = await _store.exportForMerge(id);
      return card != null && card.length <= _maxCard ? card : const [];
    } on Exception {
      return const [];
    }
  }

  Future<List<int>> _receive(Uint8List bytes) async {
    final bool imported;
    try {
      imported = await _store.importForMerge(bytes);
    } on Exception {
      return const [2];
    }
    if (imported) _onImported();
    return [imported ? 1 : 0];
  }
}

class NearbyMergeClient {
  NearbyMergeClient._(this._http, this._origin, this._id, this._secrets);

  static Future<NearbyMergeClient?> connect({
    required InternetAddress address,
    required int port,
    required String name,
    required NearbyConfirmation confirm,
  }) async {
    if (!_localAddress(address) || port < 1 || port > 65535) {
      throw const NearbyMergeException();
    }
    final origin = Uri(scheme: 'http', host: address.address, port: port);
    final http = HttpClient()
      ..connectionTimeout = _requestTimeout
      ..findProxy = (_) => 'DIRECT';
    NearbyMergeClient? client;
    try {
      final clientName = _readName(name);
      final pair = await _x25519.newKeyPair();
      final key = (await pair.extractPublicKey()).bytes;
      final salt = _randomBytes(32);
      final commitment = await _commit(key, salt, clientName);
      final hello = _readJson(
        await _post(
          http,
          origin.replace(path: '/hello'),
          utf8.encode(
            jsonEncode({
              'name': clientName,
              'commitment': base64Encode(commitment),
            }),
          ),
          _maxHandshake,
        ),
      );
      final id = hello['id'];
      if (id is! String || !_sessionId.hasMatch(id)) {
        throw const FormatException();
      }
      final serverName = _readName(hello['name']);
      final serverKey = _readBase64(hello['key'], 32);
      final secrets = await _derive(
        pair: pair,
        peerKey: serverKey,
        clientKey: key,
        serverKey: serverKey,
        id: id,
        clientName: clientName,
        serverName: serverName,
        salt: salt,
      );
      await _post(
        http,
        origin.replace(path: '/reveal/$id'),
        utf8.encode(
          jsonEncode({'key': base64Encode(key), 'salt': base64Encode(salt)}),
        ),
        0,
      );
      client = NearbyMergeClient._(http, origin, id, secrets);
      if (!await confirm(serverName, secrets.code).timeout(_pairTimeout)) {
        await client.close();
        return null;
      }
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < _pairTimeout) {
        final status = _readFlag(await client._request('status', const [], 1));
        if (status == 1) return client;
        if (status == 2) {
          await client.close();
          return null;
        }
        if (status != 0) throw const FormatException();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      throw TimeoutException('Nearby approval timed out.');
    } on Object {
      if (client != null) {
        await client.close();
      } else {
        http.close(force: true);
      }
      throw const NearbyMergeException();
    }
  }

  final HttpClient _http;
  final Uri _origin;
  final String _id;
  final _Secrets _secrets;
  Future<void> _pending = Future<void>.value();
  int _sequence = 0;
  bool _closed = false;
  bool _broken = false;

  Future<List<MergeCardRef>> manifest() async {
    try {
      return _decodeManifest(
        await _request('manifest', const [], _maxManifest),
      );
    } on FormatException {
      throw const NearbyMergeException();
    }
  }

  /// Returns null when the card is no longer available on the peer.
  Future<Uint8List?> downloadCard(String id) async {
    if (!_cardId.hasMatch(id)) {
      throw const NearbyMergeException();
    }
    final data = await _request('read', utf8.encode(id), _maxCard);
    return data.isEmpty ? null : data;
  }

  Future<bool> sendCard(Uint8List data) async {
    if (data.isEmpty || data.length > _maxCard) {
      throw const NearbyMergeException();
    }
    try {
      final flag = _readFlag(await _request('write', data, 1));
      return switch (flag) {
        0 => false,
        1 => true,
        2 => throw const NearbyCardTransferException(),
        _ => throw const NearbyMergeException(),
      };
    } on FormatException {
      throw const NearbyMergeException();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _pending.timeout(const Duration(seconds: 3));
      if (!_broken) {
        await _exchange(
          'close',
          const [],
          0,
        ).timeout(const Duration(seconds: 3));
      }
    } on Object {
      // The server also expires sessions when a device loses its connection.
    } finally {
      _http.close(force: true);
    }
  }

  Future<Uint8List> _request(String operation, List<int> data, int max) {
    if (_closed) return Future.error(const NearbyMergeException());
    final request = _pending.then((_) => _exchange(operation, data, max));
    _pending = request.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return request;
  }

  Future<Uint8List> _exchange(String operation, List<int> data, int max) async {
    if (_broken) throw const NearbyMergeException();
    final sequence = _sequence++;
    try {
      final request = await _seal(
        data,
        _secrets.client,
        _id,
        operation,
        sequence,
        response: false,
      );
      final reply = await _post(
        _http,
        _origin.replace(path: '/session/$_id/$operation'),
        request,
        max + _frameOverhead,
      );
      return await _open(
        reply,
        _secrets.server,
        _id,
        operation,
        sequence,
        response: true,
      );
    } on Object {
      _broken = true;
      _http.close(force: true);
      throw const NearbyMergeException();
    }
  }
}

class _Session {
  _Session(this.name, this.commitment, this.pair, this.publicKey);

  final String name;
  final List<int> commitment;
  final List<int> publicKey;
  final created = DateTime.now();
  DateTime lastUsed = DateTime.now();
  SimpleKeyPair? pair;
  _Secrets? secrets;
  bool? approval;
  int sequence = 0;
  bool busy = false;

  bool expired(DateTime now) =>
      !busy &&
      (approval == true
          ? now.difference(lastUsed) >= const Duration(minutes: 10) ||
                now.difference(created) >= const Duration(minutes: 30)
          : now.difference(created) >= _pairTimeout);
}

typedef _Secrets = ({SecretKey client, SecretKey server, String code});

Future<_Secrets> _derive({
  required SimpleKeyPair pair,
  required List<int> peerKey,
  required List<int> clientKey,
  required List<int> serverKey,
  required String id,
  required String clientName,
  required String serverName,
  required List<int> salt,
}) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: pair,
    remotePublicKey: SimplePublicKey(peerKey, type: KeyPairType.x25519),
  );
  if ((await shared.extractBytes()).every((byte) => byte == 0)) {
    throw const FormatException();
  }
  final material = await Hkdf(hmac: Hmac.sha256(), outputLength: 68).deriveKey(
    secretKey: shared,
    nonce: salt,
    info: [
      ...utf8.encode(jsonEncode([_protocol, id, clientName, serverName])),
      ...clientKey,
      ...serverKey,
    ],
  );
  final bytes = Uint8List.fromList(material.bytes);
  final code = ByteData.sublistView(bytes).getUint32(64) % 1000000;
  return (
    client: SecretKey(bytes.sublist(0, 32)),
    server: SecretKey(bytes.sublist(32, 64)),
    code: code.toString().padLeft(6, '0'),
  );
}

// Committing to the initiator key before receiving the responder key prevents
// either side choosing a key after seeing both contributions to the code.
Future<List<int>> _commit(List<int> key, List<int> salt, String name) async =>
    (await _sha.hash([...key, ...salt, ...utf8.encode(name)])).bytes;

Uint8List _randomBytes(int length) =>
    Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var i = 0; i < left.length; i++) {
    difference |= left[i] ^ right[i];
  }
  return difference == 0;
}

Uint8List _nonce(int sequence) {
  final nonce = Uint8List(12);
  ByteData.sublistView(nonce).setUint64(4, sequence);
  return nonce;
}

List<int> _context(String id, String operation, int sequence, bool response) {
  final direction = response ? 'response' : 'request';
  return utf8.encode(
    '$_protocol POST /session/$id/$operation $direction $sequence',
  );
}

Future<Uint8List> _seal(
  List<int> clear,
  SecretKey key,
  String id,
  String operation,
  int sequence, {
  required bool response,
}) async {
  final box = await _aes.encrypt(
    clear,
    secretKey: key,
    nonce: _nonce(sequence),
    aad: _context(id, operation, sequence, response),
  );
  final frame = Uint8List(box.cipherText.length + _frameOverhead);
  ByteData.sublistView(frame).setUint64(0, sequence);
  frame.setRange(8, 8 + box.cipherText.length, box.cipherText);
  frame.setRange(frame.length - 16, frame.length, box.mac.bytes);
  return frame;
}

Future<Uint8List> _open(
  Uint8List frame,
  SecretKey key,
  String id,
  String operation,
  int sequence, {
  required bool response,
}) async {
  if (frame.length < _frameOverhead ||
      ByteData.sublistView(frame).getUint64(0) != sequence) {
    throw const FormatException();
  }
  final macAt = frame.length - 16;
  final box = SecretBox(
    Uint8List.sublistView(frame, 8, macAt),
    nonce: _nonce(sequence),
    mac: Mac(Uint8List.sublistView(frame, macAt)),
  );
  final clear = await _aes.decrypt(
    box,
    secretKey: key,
    aad: _context(id, operation, sequence, response),
  );
  return clear is Uint8List ? clear : Uint8List.fromList(clear);
}

Future<Uint8List> _post(
  HttpClient http,
  Uri uri,
  List<int> data,
  int max,
) async {
  final request = await http.postUrl(uri).timeout(_requestTimeout);
  request.followRedirects = false;
  request.contentLength = data.length;
  request.headers.contentType = ContentType.binary;
  request.add(data);
  final response = await request.close().timeout(_requestTimeout);
  if (response.statusCode != HttpStatus.ok) throw const NearbyMergeException();
  return _read(response, max);
}

Future<Uint8List> _read(Stream<List<int>> stream, int max) async {
  final bytes = BytesBuilder(copy: false);
  final watch = Stopwatch()..start();
  await for (final chunk in stream.timeout(_requestTimeout)) {
    if (watch.elapsed >= _requestTimeout) {
      throw TimeoutException('Nearby message timed out.');
    }
    if (chunk.length > max - bytes.length) {
      throw const _HttpFailure(HttpStatus.requestEntityTooLarge);
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Map<String, Object?> _readJson(Uint8List bytes) {
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map<String, Object?>) throw const FormatException();
  return value;
}

String _readName(Object? value) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > 64 ||
      _unsafeName.hasMatch(value)) {
    throw const FormatException();
  }
  return value;
}

List<int> _readBase64(Object? value, int length) {
  if (value is! String || value.length != ((length + 2) ~/ 3) * 4) {
    throw const FormatException();
  }
  final decoded = base64Decode(value);
  if (decoded.length != length) throw const FormatException();
  return decoded;
}

int _readFlag(Uint8List value) {
  if (value.length != 1) throw const FormatException();
  return value.single;
}

List<int> _encodeManifest(List<MergeCardRef> cards) {
  final encoded = utf8.encode(
    jsonEncode([
      for (final card in cards) {'id': card.id, 'keys': card.keys},
    ]),
  );
  if (encoded.length > _maxManifest) throw const FormatException();
  return encoded;
}

List<MergeCardRef> _decodeManifest(Uint8List bytes) {
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! List<Object?> || value.length > 8000) {
    throw const FormatException();
  }
  final seen = <String>{};
  final cards = <MergeCardRef>[];
  for (final row in value) {
    if (row case {'id': final String id, 'keys': final List<Object?> keys}
        when _cardId.hasMatch(id) &&
            seen.add(id) &&
            keys.isNotEmpty &&
            keys.length <= 4 &&
            keys.every((key) => key is String && _key.hasMatch(key))) {
      cards.add(MergeCardRef(id: id, keys: keys.cast<String>()));
    } else {
      throw const FormatException();
    }
  }
  return cards;
}

bool _localAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal) return true;
  final bytes = address.rawAddress;
  if (bytes.length == 4) return _privateIPv4(bytes);
  if (bytes.length != 16) return false;
  if ((bytes[0] & 0xfe) == 0xfc) return true;
  return bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 255 &&
      bytes[11] == 255 &&
      _privateIPv4(bytes.sublist(12));
}

bool _privateIPv4(List<int> bytes) =>
    bytes[0] == 10 ||
    bytes[0] == 127 ||
    (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
    (bytes[0] == 192 && bytes[1] == 168) ||
    (bytes[0] == 169 && bytes[1] == 254);

class _HttpFailure implements Exception {
  const _HttpFailure(this.status);

  final int status;
}
