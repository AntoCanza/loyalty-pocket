import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum CardCodeFormat {
  code128('Code 128'),
  code39('Code 39'),
  code93('Code 93'),
  codabar('Codabar'),
  ean13('EAN-13'),
  ean8('EAN-8'),
  upcA('UPC-A'),
  upcE('UPC-E'),
  itf('ITF'),
  qr('QR code'),
  dataMatrix('Data Matrix'),
  pdf417('PDF417'),
  aztec('Aztec');

  const CardCodeFormat(this.label);

  final String label;
}

class LoyaltyCard {
  const LoyaltyCard({
    required this.id,
    required this.name,
    required this.photoPath,
    this.code,
    this.format,
    this.note,
  });

  final String id;
  final String name;
  final String? photoPath;
  final String? code;
  final CardCodeFormat? format;
  final String? note;
}

class DuplicateCardException implements Exception {
  const DuplicateCardException(this.existing);

  final LoyaltyCard existing;
}

class MergeCardRef {
  const MergeCardRef({required this.id, required this.keys});

  final String id;
  final List<String> keys;
}

typedef _CardFields = ({
  String name,
  String? code,
  CardCodeFormat? format,
  String? note,
});
typedef _CardImage = ({Uint8List bytes, String extension});

class CardStore {
  CardStore(Directory root) : _root = root.absolute;

  static const maxNameLength = 80;
  static const maxCodeLength = 4096;
  static const maxNoteLength = 160;
  static const maxPhotoBytes = 20 * 1024 * 1024;

  static const _version = 1;
  static const _maxEncodedPhotoLength = ((maxPhotoBytes + 2) ~/ 3) * 4;
  static const _maxShareBytes = _maxEncodedPhotoLength + 32 * 1024;
  static final _cardId = RegExp(r'^[a-f0-9]{48}$');
  static final _photoName = RegExp(
    r'^photo-[a-f0-9]{32}\.(jpe?g|png|gif|webp|heic|heif)$',
  );
  static final _retailDigits = RegExp(r'^[0-9]{12,13}$');

  final Directory _root;
  final Random _random = Random.secure();
  Future<void> _pending = Future.value();

  Future<List<LoyaltyCard>> load() => _run(() async {
    final cards = await _readCards().toList();
    cards.sort((a, b) => b.id.compareTo(a.id));
    return cards;
  });

  Stream<LoyaltyCard> _readCards() async* {
    await _root.create(recursive: true);
    await for (final entry in _root.list(followLinks: false)) {
      final id = _basename(entry.path);
      if (entry is! Directory || !_isCardId(id)) continue;
      try {
        yield await _readCard(entry, id);
      } on FormatException {
        // A damaged card should not hide the rest of the wallet.
      } on PathNotFoundException {
        // Skip a card with missing metadata or photo.
      }
    }
  }

  Future<LoyaltyCard?> findDuplicate(
    String code,
    CardCodeFormat? format, {
    String? excludingId,
  }) => _run(() => _findDuplicate(code, format, excludingId: excludingId));

  Future<LoyaltyCard?> _findDuplicate(
    String? code,
    CardCodeFormat? format, {
    String? excludingId,
  }) async {
    if (code == null || code.isEmpty) return null;
    final retailCode = _retailCode(code, format);
    await for (final card in _readCards()) {
      final savedCode = card.code;
      if (card.id == excludingId || savedCode == null) continue;
      if (savedCode == code ||
          (retailCode != null &&
              retailCode == _retailCode(savedCode, card.format))) {
        return card;
      }
    }
    return null;
  }

  static String? _retailCode(String code, CardCodeFormat? format) {
    // Scanners can represent UPC-A as EAN-13 with an extra leading zero.
    if (!_retailDigits.hasMatch(code)) return null;
    return switch (format) {
      CardCodeFormat.upcA when code.length == 12 => '0$code',
      CardCodeFormat.ean13 when code.length == 13 => code,
      _ => null,
    };
  }

  Future<void> _requireUniqueCode(
    _CardFields fields, {
    String? excludingId,
  }) async {
    final existing = await _findDuplicate(
      fields.code,
      fields.format,
      excludingId: excludingId,
    );
    if (existing != null) throw DuplicateCardException(existing);
  }

  Future<LoyaltyCard> save({
    LoyaltyCard? existing,
    required String name,
    required File? photo,
    String? code,
    CardCodeFormat? format,
    String? note,
  }) => _run(() async {
    if (existing == null) {
      final fields = _validateFields(name, code, format, note);
      final image = photo == null ? null : await _readPhoto(photo);
      return _createCard(fields, image);
    }

    final directory = _cardDirectory(existing.id);
    final previous = await _readCard(directory, existing.id);
    final fields = _validateFields(name, code, format, note ?? previous.note);
    if (fields.code != previous.code || fields.format != previous.format) {
      await _requireUniqueCode(fields, excludingId: previous.id);
    }
    final previousPhotoPath = previous.photoPath;
    if (photo == null || photo.absolute.path == previousPhotoPath) {
      _requireCardContent(fields, hasPhoto: previousPhotoPath != null);
      return _updateMetadata(directory, previous, fields);
    }

    final image = await _readPhoto(photo);
    final newPhoto = await _writePhoto(directory, image);
    try {
      await _writeMetadata(directory, fields, _basename(newPhoto.path));
    } catch (_) {
      await _tryDelete(newPhoto);
      rethrow;
    }
    if (previousPhotoPath != null) {
      await _tryDelete(File(previousPhotoPath));
    }
    return _toCard(previous.id, fields, newPhoto.path);
  });

  Future<LoyaltyCard> updateNote(LoyaltyCard card, String? note) =>
      _run(() async {
        final directory = _cardDirectory(card.id);
        final previous = await _readCard(directory, card.id);
        return _updateMetadata(directory, previous, (
          name: previous.name,
          code: previous.code,
          format: previous.format,
          note: _validateNote(note),
        ));
      });

  Future<LoyaltyCard> _updateMetadata(
    Directory directory,
    LoyaltyCard previous,
    _CardFields fields,
  ) async {
    final photoPath = previous.photoPath;
    await _writeMetadata(
      directory,
      fields,
      photoPath == null ? null : _basename(photoPath),
    );
    return _toCard(previous.id, fields, photoPath);
  }

  Future<void> delete(LoyaltyCard card) => _run(() async {
    final directory = _cardDirectory(card.id);
    if (!await directory.exists()) return;
    final removed = await directory.rename(
      _join(_root, '.removed-${_randomHex()}'),
    );
    await _tryDelete(removed);
  });

  Future<File> exportCard(LoyaltyCard card, Directory tempRoot) =>
      _run(() async {
        final current = await _readCard(_cardDirectory(card.id), card.id);
        final data = await _encodeShare(current);
        final directory = Directory(_join(tempRoot, 'loyalty-pocket-share'));
        await directory.create(recursive: true);
        final file = File(_join(directory, '${card.id}.loyalty-card.json'));
        await _writeAtomically(file, data);
        return file;
      });

  Future<List<MergeCardRef>> mergeManifest() => _run(() async {
    final manifest = <MergeCardRef>[];
    await for (final card in _readCards()) {
      final code = card.code;
      final photoPath = card.photoPath;
      final retailCode = code == null ? null : _retailCode(code, card.format);
      final keys = [
        _mergeKey('id', card.id),
        if (code != null) _mergeKey('code', code),
        if (retailCode != null) _mergeKey('retail', retailCode),
        if (code == null && photoPath != null)
          _mergeKey('photo', await _photoHash(photoPath)),
      ];
      manifest.add(MergeCardRef(id: card.id, keys: keys));
    }
    return manifest;
  });

  Future<Uint8List?> exportForMerge(String id) => _run(() async {
    final directory = _cardDirectory(id);
    if (!await directory.exists()) return null;
    final current = await _readCard(directory, id);
    final data = await _encodeShare(current);
    return utf8.encode(jsonEncode({...data, 'id': id}));
  });

  Future<bool> importForMerge(Uint8List bytes) => _run(() async {
    if (bytes.length > _maxShareBytes) {
      throw const FormatException('This file is too large.');
    }
    final data = _decodeJson(bytes);
    final id = data['id'];
    if (id is! String || !_isCardId(id)) {
      throw const FormatException('The card ID is invalid.');
    }
    final fields = _decodeFields(data);
    final image = _decodeSharePhoto(data);
    _requireCardContent(fields, hasPhoto: image != null);

    if (await FileSystemEntity.type(
          _cardDirectory(id).path,
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      return false;
    }
    if (fields.code == null &&
        image != null &&
        await _hasPhotoOnlyMatch(image.bytes)) {
      return false;
    }

    try {
      await _createCard(fields, image, id: id);
      return true;
    } on DuplicateCardException {
      return false;
    }
  });

  Future<bool> _hasPhotoOnlyMatch(Uint8List photo) async {
    final digest = sha256.convert(photo).toString();
    await for (final card in _readCards()) {
      final photoPath = card.photoPath;
      if (card.code == null &&
          photoPath != null &&
          await _photoHash(photoPath) == digest) {
        return true;
      }
    }
    return false;
  }

  static Future<String> _photoHash(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();

  static String _mergeKey(String kind, String value) =>
      sha256.convert(utf8.encode('$kind:$value')).toString();

  static Future<Map<String, Object?>> _encodeShare(LoyaltyCard card) async {
    final data = _encodeFields((
      name: card.name,
      code: card.code,
      format: card.format,
      note: card.note,
    ));
    final photoPath = card.photoPath;
    if (photoPath != null) {
      final image = await _readPhoto(File(photoPath));
      data['photoExtension'] = image.extension;
      data['photoBase64'] = base64Encode(image.bytes);
    }
    return data;
  }

  Future<LoyaltyCard> importCard(Stream<List<int>> source) => _run(() async {
    final fileBytes = BytesBuilder(copy: false);
    await for (final chunk in source) {
      if (fileBytes.length + chunk.length > _maxShareBytes) {
        throw const FormatException('This file is too large.');
      }
      fileBytes.add(chunk);
    }
    final data = _decodeJson(fileBytes.takeBytes());
    final fields = _decodeFields(data);
    return _createCard(fields, _decodeSharePhoto(data));
  });

  static _CardImage? _decodeSharePhoto(Map<String, Object?> data) {
    if (!data.containsKey('photoBase64') &&
        !data.containsKey('photoExtension')) {
      return null;
    }
    final encoded = data['photoBase64'];
    final extension = data['photoExtension'];
    if (encoded is! String ||
        encoded.isEmpty ||
        encoded.length > _maxEncodedPhotoLength ||
        extension is! String) {
      throw const FormatException('The shared card has an invalid photo.');
    }
    final bytes = base64Decode(encoded);
    final detectedExtension = _imageExtension(bytes, extension);
    if (detectedExtension != extension) {
      throw const FormatException('The shared card photo format is invalid.');
    }
    return (bytes: bytes, extension: detectedExtension);
  }

  Future<T> _run<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<LoyaltyCard> _createCard(
    _CardFields fields,
    _CardImage? image, {
    String? id,
  }) async {
    _requireCardContent(fields, hasPhoto: image != null);
    await _requireUniqueCode(fields);
    final cardId = id ?? _newCardId();
    final staging = Directory(
      _join(_root, '.creating-$cardId-${_randomHex()}'),
    );
    await staging.create(recursive: true);
    try {
      final photo = image == null ? null : await _writePhoto(staging, image);
      final photoName = photo == null ? null : _basename(photo.path);
      await _writeMetadata(staging, fields, photoName);
      final directory = await staging.rename(_cardDirectory(cardId).path);
      return _toCard(
        cardId,
        fields,
        photoName == null ? null : _join(directory, photoName),
      );
    } catch (_) {
      await _tryDelete(staging);
      rethrow;
    }
  }

  Future<LoyaltyCard> _readCard(Directory directory, String id) async {
    final metadata = File(_join(directory, 'card.json'));
    final data = _decodeJson(await _readLimited(metadata, 32 * 1024));
    final fields = _decodeFields(data);
    final filename = data['photo'];
    if (filename == null && data.containsKey('photo')) {
      _requireCardContent(fields, hasPhoto: false);
      return _toCard(id, fields, null);
    }
    if (filename is! String || !_photoName.hasMatch(filename)) {
      throw const FormatException('The stored card photo is invalid.');
    }
    final photo = File(_join(directory, filename));
    if (!await photo.exists()) {
      throw const FormatException('The stored card photo is missing.');
    }
    return _toCard(id, fields, photo.path);
  }

  Future<File> _writePhoto(Directory directory, _CardImage image) async {
    final filename = 'photo-${_randomHex()}.${image.extension}';
    final file = File(_join(directory, filename));
    try {
      return await file.writeAsBytes(image.bytes, flush: true);
    } catch (_) {
      await _tryDelete(file);
      rethrow;
    }
  }

  Future<void> _writeMetadata(
    Directory directory,
    _CardFields fields,
    String? photoName,
  ) => _writeAtomically(File(_join(directory, 'card.json')), {
    ..._encodeFields(fields),
    'photo': photoName,
  });

  Future<void> _writeAtomically(File target, Map<String, Object?> data) async {
    final temporary = File('${target.path}.${_randomHex()}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(data), flush: true);
      await temporary.rename(target.path);
    } catch (_) {
      await _tryDelete(temporary);
      rethrow;
    }
  }

  static Map<String, Object?> _encodeFields(_CardFields fields) => {
    'version': _version,
    'name': fields.name,
    'code': fields.code,
    'format': fields.format?.name,
    if (fields.note != null) 'note': fields.note,
  };

  static _CardFields _decodeFields(Map<String, Object?> data) {
    if (data['version'] != _version) {
      throw const FormatException('This card file version is not supported.');
    }
    final name = data['name'];
    final code = data['code'];
    final formatName = data['format'];
    final note = data['note'];
    if (name is! String ||
        (code != null && code is! String) ||
        (note != null && note is! String)) {
      throw const FormatException('The card details are invalid.');
    }
    CardCodeFormat? format;
    if (formatName != null) {
      format = CardCodeFormat.values
          .where((value) => value.name == formatName)
          .firstOrNull;
      if (format == null) {
        throw const FormatException('The barcode format is not supported.');
      }
    }
    return _validateFields(name, code as String?, format, note as String?);
  }

  static _CardFields _validateFields(
    String name,
    String? code,
    CardCodeFormat? format,
    String? note,
  ) {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || trimmedName.length > maxNameLength) {
      throw const FormatException('Enter a card name of 1 to 80 characters.');
    }
    if (code == null
        ? format != null
        : code.isEmpty || code.length > maxCodeLength) {
      throw const FormatException('The barcode details are invalid.');
    }
    return (
      name: trimmedName,
      code: code,
      format: format,
      note: _validateNote(note),
    );
  }

  static String? _validateNote(String? note) {
    final trimmed = note?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.length > maxNoteLength) {
      throw const FormatException('Enter a note of up to 160 characters.');
    }
    return trimmed;
  }

  static void _requireCardContent(
    _CardFields fields, {
    required bool hasPhoto,
  }) {
    if (!hasPhoto && fields.code == null) {
      throw const FormatException('Add a photo or a card number.');
    }
  }

  static Map<String, Object?> _decodeJson(Uint8List bytes) {
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, Object?>) {
      throw const FormatException('This file does not contain a card.');
    }
    return data;
  }

  static Future<_CardImage> _readPhoto(File photo) async {
    final bytes = await _readLimited(photo, maxPhotoBytes);
    final preferredExtension = _basename(
      photo.path,
    ).split('.').last.toLowerCase();
    return (
      bytes: bytes,
      extension: _imageExtension(bytes, preferredExtension),
    );
  }

  static Future<Uint8List> _readLimited(File file, int maxBytes) async {
    final reader = await file.open();
    try {
      final size = await reader.length();
      if (size > maxBytes) {
        throw const FormatException('This file is too large.');
      }
      return await reader.read(size);
    } finally {
      await reader.close();
    }
  }

  static String _imageExtension(Uint8List bytes, String preferredExtension) {
    if (bytes.length > maxPhotoBytes) {
      throw const FormatException('The photo must be 20 MB or smaller.');
    }
    if (bytes.length >= 12) {
      if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
        return preferredExtension == 'jpeg' ? 'jpeg' : 'jpg';
      }
      if (_matches(bytes, 0, const [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ])) {
        return 'png';
      }
      if (_matches(bytes, 0, 'GIF87a'.codeUnits) ||
          _matches(bytes, 0, 'GIF89a'.codeUnits)) {
        return 'gif';
      }
      if (_matches(bytes, 0, 'RIFF'.codeUnits) &&
          _matches(bytes, 8, 'WEBP'.codeUnits)) {
        return 'webp';
      }
      if (_matches(bytes, 4, 'ftyp'.codeUnits)) {
        final brand = ascii.decode(bytes.sublist(8, 12), allowInvalid: true);
        if (const {'heic', 'heix', 'hevc', 'hevx'}.contains(brand)) {
          return preferredExtension == 'heif' ? 'heif' : 'heic';
        }
        if (brand == 'mif1' || brand == 'msf1') {
          return preferredExtension == 'heic' ? 'heic' : 'heif';
        }
      }
    }
    throw const FormatException(
      'Choose a supported photo (JPEG, PNG, GIF, WebP, or HEIF).',
    );
  }

  static bool _matches(Uint8List bytes, int offset, List<int> signature) {
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) return false;
    }
    return true;
  }

  Directory _cardDirectory(String id) {
    if (!_isCardId(id)) {
      throw const FormatException('The card ID is invalid.');
    }
    return Directory(_join(_root, id));
  }

  static bool _isCardId(String id) => id.length == 48 && _cardId.hasMatch(id);

  String _newCardId() {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return '${time.padLeft(16, '0')}${_randomHex()}';
  }

  static LoyaltyCard _toCard(
    String id,
    _CardFields fields,
    String? photoPath,
  ) => LoyaltyCard(
    id: id,
    name: fields.name,
    photoPath: photoPath,
    code: fields.code,
    format: fields.format,
    note: fields.note,
  );

  String _randomHex() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  static String _join(Directory parent, String name) =>
      '${parent.path}${Platform.pathSeparator}$name';

  static String _basename(String path) =>
      path.split(Platform.pathSeparator).last;

  static Future<void> _tryDelete(FileSystemEntity entry) async {
    try {
      await entry.delete(recursive: entry is Directory);
    } on FileSystemException {
      // Once the card is committed, cleanup failures leave hidden files only.
    }
  }
}
