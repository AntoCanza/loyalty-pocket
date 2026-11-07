import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/card_store.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVdQAAAAASUVORK5CYII=',
);
final _gif = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
);

void main() {
  late Directory temporary;
  late Directory wallet;
  late File original;
  late CardStore store;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('loyalty-pocket-test-');
    wallet = Directory.fromUri(temporary.uri.resolve('wallet/'));
    original = File.fromUri(temporary.uri.resolve('camera.png'));
    await original.writeAsBytes(_png);
    store = CardStore(wallet);
  });

  tearDown(() => temporary.delete(recursive: true));

  test('preserves the photo and code when reopening the wallet', () async {
    final saved = await store.save(
      name: '  Corner Market  ',
      photo: original,
      code: '0001234567895',
      format: CardCodeFormat.ean13,
    );
    await original.delete();

    final restored = (await CardStore(wallet).load()).single;
    expect(restored.id, saved.id);
    expect(restored.name, 'Corner Market');
    expect(restored.code, '0001234567895');
    expect(restored.format, CardCodeFormat.ean13);
    expect(restored.photoPath, endsWith('.png'));
    expect(await File(restored.photoPath!).readAsBytes(), _png);
  });

  test(
    'shares the original bytes and preserves significant code whitespace',
    () async {
      final saved = await store.save(
        name: 'Bookshop',
        photo: original,
        code: ' 0007 ',
        format: CardCodeFormat.code128,
      );
      final shared = await store.exportCard(saved, temporary);
      expect(shared.path, endsWith('.loyalty-card.json'));

      final other = CardStore(
        Directory.fromUri(temporary.uri.resolve('other/')),
      );
      final imported = await other.importCard(shared.openRead());
      expect(imported.id, isNot(saved.id));
      expect(imported.name, saved.name);
      expect(imported.code, ' 0007 ');
      expect(imported.format, CardCodeFormat.code128);
      expect(await File(imported.photoPath!).readAsBytes(), _png);
    },
  );

  test('edits a card in place, replaces the photo, and deletes it', () async {
    final saved = await store.save(name: 'Market', photo: original);
    final renamed = await store.save(
      existing: saved,
      name: 'Main Street Market',
      photo: File(saved.photoPath!),
      code: '0012',
      format: CardCodeFormat.code128,
    );
    expect(renamed.photoPath, saved.photoPath);

    final replacement = File.fromUri(temporary.uri.resolve('replacement.gif'));
    await replacement.writeAsBytes(_gif);
    final replaced = await store.save(
      existing: renamed,
      name: renamed.name,
      photo: replacement,
    );
    expect(replaced.id, saved.id);
    expect(replaced.photoPath, endsWith('.gif'));
    expect(await File(replaced.photoPath!).readAsBytes(), _gif);
    expect(await File(saved.photoPath!).exists(), isFalse);
    expect((await store.load()).single.code, isNull);

    await store.delete(replaced);
    expect(await store.load(), isEmpty);
    expect(await File(replaced.photoPath!).exists(), isFalse);
  });

  test(
    'imports and shares an exact number without a photo or format',
    () async {
      final data = <String, Object?>{
        'version': 1,
        'name': 'Market',
        'code': ' 0007 ',
        'format': null,
      };
      final imported = await store.importCard(
        Stream.value(utf8.encode(jsonEncode(data))),
      );
      expect(imported.photoPath, isNull);
      expect(imported.format, isNull);
      expect(imported.code, ' 0007 ');
      expect(imported.note, isNull);

      final restored = (await CardStore(wallet).load()).single;
      expect(restored.id, imported.id);
      expect(restored.photoPath, isNull);
      expect(restored.code, imported.code);
      final shared = await store.exportCard(restored, temporary);
      expect(jsonDecode(await shared.readAsString()), data);
    },
  );

  test('adds a photo to an existing number-only card', () async {
    final saved = await store.save(name: 'Market', code: '0007', photo: null);
    await expectLater(
      store.save(existing: saved, name: saved.name, photo: null),
      throwsFormatException,
    );
    final updated = await store.save(
      existing: saved,
      name: saved.name,
      photo: original,
      code: saved.code,
    );
    expect(updated.id, saved.id);
    expect(updated.code, saved.code);
    expect(await File(updated.photoPath!).readAsBytes(), _png);
  });

  test('updates, shares, and clears an optional card note', () async {
    final saved = await store.save(
      name: 'Market',
      photo: original,
      code: '0007',
      note: '  Use at checkout  ',
    );
    final renamed = await store.save(
      existing: saved,
      name: 'Main Street Market',
      photo: null,
      code: '0008',
    );
    expect(renamed.note, 'Use at checkout');
    final updated = await store.updateNote(saved, '  Weekly shop  ');
    expect(updated.name, renamed.name);
    expect(updated.code, renamed.code);
    expect(updated.photoPath, saved.photoPath);
    expect(updated.note, 'Weekly shop');

    final restored = (await CardStore(wallet).load()).single;
    expect(restored.note, updated.note);
    final shared = await store.exportCard(restored, temporary);
    final other = CardStore(Directory.fromUri(temporary.uri.resolve('other/')));
    final imported = await other.importCard(shared.openRead());
    expect(imported.note, updated.note);
    expect(await File(imported.photoPath!).readAsBytes(), _png);

    final cleared = await store.save(
      existing: restored,
      name: restored.name,
      photo: null,
      code: restored.code,
      note: '',
    );
    expect(cleared.note, isNull);
    expect((await CardStore(wallet).load()).single.note, isNull);
  });

  test('saves and shares notes at the visible character limit', () async {
    const character = '\u{1F469}\u200D\u{1F4BB}';
    final note = character * CardStore.maxNoteLength;
    final saved = await store.save(name: 'Market', photo: null, code: '0007');

    final updated = await store.updateNote(saved, note);
    expect((await store.load()).single.note, note);

    final shared = await store.exportCard(updated, temporary);
    final other = CardStore(Directory.fromUri(temporary.uri.resolve('other/')));
    expect((await other.importCard(shared.openRead())).note, note);

    await expectLater(
      store.updateNote(saved, '$note$character'),
      throwsFormatException,
    );
    final oversizedCluster = 'a${'\u0301' * (20 * 1024)}';
    await expectLater(
      store.updateNote(saved, oversizedCluster),
      throwsFormatException,
    );
    expect((await store.load()).single.note, note);
  });

  test('saves card names at the visible character limit', () async {
    const character = '\u{1F469}\u200D\u{1F4BB}';
    final name = character * CardStore.maxNameLength;
    final saved = await store.save(name: name, photo: null, code: '0007');
    expect((await store.load()).single.name, name);

    await expectLater(
      store.save(
        existing: saved,
        name: '$name$character',
        photo: null,
        code: saved.code,
      ),
      throwsFormatException,
    );
    expect((await store.load()).single.name, name);
  });

  test('rejects repeated codes during queued saves and imports', () async {
    final first = store.save(
      name: 'Market',
      photo: null,
      code: '0007',
      note: 'Weekly shop',
    );
    final second = store.save(
      name: 'Duplicate',
      photo: null,
      code: '0007',
      format: CardCodeFormat.code128,
    );
    final rejected = expectLater(
      second,
      throwsA(
        isA<DuplicateCardException>()
            .having((error) => error.existing.name, 'name', 'Market')
            .having((error) => error.existing.note, 'note', 'Weekly shop'),
      ),
    );
    final saved = await first;
    await rejected;
    final detected = await store.findDuplicate('0007', CardCodeFormat.qr);
    expect(detected?.id, saved.id);
    expect(
      await store.findDuplicate('0007', null, excludingId: saved.id),
      isNull,
    );

    final shared = await store.exportCard(saved, temporary);
    await expectLater(
      store.importCard(shared.openRead()),
      throwsA(
        isA<DuplicateCardException>().having(
          (error) => error.existing.id,
          'existing ID',
          saved.id,
        ),
      ),
    );
    expect((await store.load()).single.id, saved.id);
  });

  test(
    'leaves legacy duplicates editable but rejects a conflicting edit',
    () async {
      const code = '036000291452';
      final first = await store.save(
        name: 'Market',
        photo: null,
        code: code,
        format: CardCodeFormat.upcA,
      );
      final second = await store.save(name: 'Other', photo: null, code: '0008');
      expect(
        (await store.findDuplicate('0$code', CardCodeFormat.ean13))?.id,
        first.id,
      );
      expect(
        await store.findDuplicate('0$code', CardCodeFormat.code128),
        isNull,
      );
      await expectLater(
        store.save(
          existing: second,
          name: second.name,
          photo: null,
          code: '0$code',
          format: CardCodeFormat.ean13,
        ),
        throwsA(isA<DuplicateCardException>()),
      );

      final metadata = File.fromUri(
        wallet.uri.resolve('${second.id}/card.json'),
      );
      await metadata.writeAsString(
        jsonEncode({
          'version': 1,
          'name': second.name,
          'code': code,
          'format': 'upcA',
          'photo': null,
        }),
      );
      final updated = await store.save(
        existing: second,
        name: 'Legacy duplicate',
        photo: null,
        code: code,
        format: CardCodeFormat.upcA,
        note: 'Keep both old cards',
      );
      expect(updated.id, second.id);
      expect(updated.note, 'Keep both old cards');
      expect(await store.load(), hasLength(2));
    },
  );

  test(
    'merges a card with its stable ID and keeps later local edits',
    () async {
      final source = await store.save(
        name: 'Market',
        photo: original,
        code: '0007',
        note: 'Source note',
      );
      final manifest = (await store.mergeManifest()).single;
      expect(manifest.id, source.id);
      expect(manifest.keys, hasLength(2));
      expect(manifest.keys, everyElement(matches(RegExp(r'^[0-9a-f]{64}$'))));
      expect(await store.exportForMerge('0' * 48), isNull);

      final bytes = (await store.exportForMerge(source.id))!;
      final receiver = CardStore(
        Directory.fromUri(temporary.uri.resolve('receiver/')),
      );
      expect(
        await Future.wait([
          receiver.importForMerge(bytes),
          receiver.importForMerge(bytes),
        ]),
        [true, false],
      );
      final received = (await receiver.load()).single;
      expect(received.id, source.id);
      expect(received.note, source.note);
      expect(received.code, source.code);
      expect(await File(received.photoPath!).readAsBytes(), _png);
      expect((await receiver.mergeManifest()).single.keys, manifest.keys);

      final newPhoto = File.fromUri(temporary.uri.resolve('local.gif'));
      await newPhoto.writeAsBytes(_gif);
      await receiver.save(
        existing: received,
        name: 'Local name',
        code: '0008',
        note: 'Local note',
        photo: newPhoto,
      );
      expect(await receiver.importForMerge(bytes), isFalse);
      final unchanged = (await receiver.load()).single;
      expect(unchanged.name, 'Local name');
      expect(unchanged.code, '0008');
      expect(unchanged.note, 'Local note');
      expect(await File(unchanged.photoPath!).readAsBytes(), _gif);

      final data = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      for (final id in ['../outside', '${source.id}\n']) {
        await expectLater(
          receiver.importForMerge(utf8.encode(jsonEncode({...data, 'id': id}))),
          throwsFormatException,
        );
      }
      expect(await receiver.load(), hasLength(1));
    },
  );

  test(
    'merges equivalent barcodes and identical photo-only cards once',
    () async {
      const code = '036000291452';
      final sourceCode = await store.save(
        name: 'Source barcode',
        photo: null,
        code: code,
        format: CardCodeFormat.upcA,
      );
      final sourcePhoto = await store.save(
        name: 'Source photo',
        photo: original,
      );
      final receiver = CardStore(
        Directory.fromUri(temporary.uri.resolve('receiver/')),
      );
      final localCode = await receiver.save(
        name: 'Local barcode',
        note: 'Local note',
        photo: null,
        code: '0$code',
        format: CardCodeFormat.ean13,
      );
      final localPhoto = await receiver.save(
        name: 'Local photo',
        photo: original,
      );
      final sourceRefs = {
        for (final ref in await store.mergeManifest()) ref.id: ref,
      };
      final localRefs = {
        for (final ref in await receiver.mergeManifest()) ref.id: ref,
      };
      expect(
        sourceRefs[sourceCode.id]!.keys.any(
          localRefs[localCode.id]!.keys.contains,
        ),
        isTrue,
      );
      expect(
        sourceRefs[sourcePhoto.id]!.keys.any(
          localRefs[localPhoto.id]!.keys.contains,
        ),
        isTrue,
      );
      expect(
        await receiver.importForMerge(
          (await store.exportForMerge(sourceCode.id))!,
        ),
        isFalse,
      );
      expect(
        await receiver.importForMerge(
          (await store.exportForMerge(sourcePhoto.id))!,
        ),
        isFalse,
      );

      final received = {
        for (final card in await receiver.load()) card.id: card,
      };
      expect(received.keys, unorderedEquals([localCode.id, localPhoto.id]));
      expect(received[localCode.id]!.note, 'Local note');
      expect(received[localPhoto.id]!.name, 'Local photo');
      expect(
        await File(received[localPhoto.id]!.photoPath!).readAsBytes(),
        _png,
      );
    },
  );

  test('rejects invalid shared files without creating cards', () async {
    final share = File.fromUri(
      temporary.uri.resolve('invalid.loyalty-card.json'),
    );
    final data = <String, Object?>{
      'version': 1,
      'name': 'Market',
      'photoExtension': 'png',
      'photoBase64': base64Encode(_png),
    };
    for (final changes in [
      {'version': 2},
      {'photoExtension': '../png'},
      {'photoBase64': base64Encode(utf8.encode('This is plain text.'))},
      {'format': 'qr'},
      {'note': 123},
      {'note': 'x' * (CardStore.maxNoteLength + 1)},
      {'photoBase64': null, 'code': '0007'},
      {'photoExtension': null, 'code': '0007'},
    ]) {
      await share.writeAsString(jsonEncode({...data, ...changes}));
      await expectLater(
        store.importCard(share.openRead()),
        throwsFormatException,
      );
    }
    for (final malformed in [
      {'version': 1, 'name': 'Market'},
      {
        'version': 1,
        'name': 'Market',
        'code': '0007',
        'photoBase64': base64Encode(_png),
      },
    ]) {
      await expectLater(
        store.importCard(Stream.value(utf8.encode(jsonEncode(malformed)))),
        throwsFormatException,
      );
    }
    expect(await store.load(), isEmpty);
  });
}
