import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
  });

  final String id;
  final String name;
  final String photoPath;
  final String? code;
  final CardCodeFormat? format;
}

typedef _CardFields = ({String name, String? code, CardCodeFormat? format});

class CardStore {
  CardStore(Directory root) : _root = root.absolute;

  static const maxNameLength = 80;
  static const maxCodeLength = 4096;
  static const maxPhotoBytes = 20 * 1024 * 1024;

  static const _version = 1;
  static const _maxEncodedPhotoLength = ((maxPhotoBytes + 2) ~/ 3) * 4;
  static const _maxShareBytes = _maxEncodedPhotoLength + 32 * 1024;
  static final _cardId = RegExp(r'^[a-f0-9]{48}$');
  static final _photoName = RegExp(
    r'^photo-[a-f0-9]{32}\.(jpe?g|png|gif|webp|heic|heif)$',
  );

  final Directory _root;
  final Random _random = Random.secure();
  Future<void> _pending = Future.value();

  Future<List<LoyaltyCard>> load() => _run(() async {
    await _root.create(recursive: true);
    final cards = <LoyaltyCard>[];
    await for (final entry in _root.list(followLinks: false)) {
      final id = _basename(entry.path);
      if (entry is! Directory || !_cardId.hasMatch(id)) continue;
      try {
        cards.add(await _readCard(entry, id));
      } on FormatException {
        // A damaged card should not hide the rest of the wallet.
      } on PathNotFoundException {
        // Skip a card with missing metadata or photo.
      }
    }
    cards.sort((a, b) => b.id.compareTo(a.id));
    return cards;
  });

  Future<LoyaltyCard> save({
    LoyaltyCard? existing,
    required String name,
    required File photo,
    String? code,
    CardCodeFormat? format,
  }) => _run(() async {
    final fields = _validateFields(name, code, format);
    if (existing == null) {
      final image = await _readPhoto(photo);
      return _createCard(fields, image);
    }

    final directory = _cardDirectory(existing.id);
    final previous = await _readCard(directory, existing.id);
    if (photo.absolute.path == previous.photoPath) {
      await _writeMetadata(directory, fields, _basename(previous.photoPath));
      return _toCard(previous.id, fields, previous.photoPath);
    }

    final image = await _readPhoto(photo);
    final newPhoto = await _writePhoto(directory, image);
    try {
      await _writeMetadata(directory, fields, _basename(newPhoto.path));
    } catch (_) {
      await _tryDelete(newPhoto);
      rethrow;
    }
    await _tryDelete(File(previous.photoPath));
    return _toCard(previous.id, fields, newPhoto.path);
  });

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
        final image = await _readPhoto(File(current.photoPath));
        final directory = Directory(_join(tempRoot, 'loyalty-pocket-share'));
        await directory.create(recursive: true);
        final file = File(_join(directory, '${card.id}.loyalty-card.json'));
        await _writeAtomically(file, {
          ..._encodeFields((
            name: current.name,
            code: current.code,
            format: current.format,
          )),
          'photoExtension': image.extension,
          'photoBase64': base64Encode(image.bytes),
        });
        return file;
      });

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
    return _createCard(fields, (bytes: bytes, extension: detectedExtension));
  });

  Future<T> _run<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<LoyaltyCard> _createCard(
    _CardFields fields,
    ({Uint8List bytes, String extension}) image,
  ) async {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final id = '${time.padLeft(16, '0')}${_randomHex()}';
    final staging = Directory(_join(_root, '.creating-$id'));
    await staging.create(recursive: true);
    try {
      final photo = await _writePhoto(staging, image);
      await _writeMetadata(staging, fields, _basename(photo.path));
      final directory = await staging.rename(_cardDirectory(id).path);
      return _toCard(id, fields, _join(directory, _basename(photo.path)));
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
    if (filename is! String || !_photoName.hasMatch(filename)) {
      throw const FormatException('The stored card photo is invalid.');
    }
    final photo = File(_join(directory, filename));
    if (!await photo.exists()) {
      throw const FormatException('The stored card photo is missing.');
    }
    return _toCard(id, fields, photo.path);
  }

  Future<File> _writePhoto(
    Directory directory,
    ({Uint8List bytes, String extension}) image,
  ) async {
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
    String photoName,
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
  };

  static _CardFields _decodeFields(Map<String, Object?> data) {
    if (data['version'] != _version) {
      throw const FormatException('This card file version is not supported.');
    }
    final name = data['name'];
    final code = data['code'];
    final formatName = data['format'];
    if (name is! String || (code != null && code is! String)) {
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
    return _validateFields(name, code as String?, format);
  }

  static _CardFields _validateFields(
    String name,
    String? code,
    CardCodeFormat? format,
  ) {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || trimmedName.length > maxNameLength) {
      throw const FormatException('Enter a card name of 1 to 80 characters.');
    }
    if ((code == null) != (format == null) ||
        (code != null && (code.isEmpty || code.length > maxCodeLength))) {
      throw const FormatException('The barcode details are invalid.');
    }
    return (name: trimmedName, code: code, format: format);
  }

  static Map<String, Object?> _decodeJson(Uint8List bytes) {
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, Object?>) {
      throw const FormatException('This file does not contain a card.');
    }
    return data;
  }

  static Future<({Uint8List bytes, String extension})> _readPhoto(
    File photo,
  ) async {
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
    if (!_cardId.hasMatch(id)) {
      throw const FormatException('The card ID is invalid.');
    }
    return Directory(_join(_root, id));
  }

  static LoyaltyCard _toCard(String id, _CardFields fields, String photoPath) =>
      LoyaltyCard(
        id: id,
        name: fields.name,
        photoPath: photoPath,
        code: fields.code,
        format: fields.format,
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
