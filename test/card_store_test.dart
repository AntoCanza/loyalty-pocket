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
    expect(await File(restored.photoPath).readAsBytes(), _png);
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
      expect(await File(imported.photoPath).readAsBytes(), _png);
    },
  );

  test('edits a card in place, replaces the photo, and deletes it', () async {
    final saved = await store.save(name: 'Market', photo: original);
    final renamed = await store.save(
      existing: saved,
      name: 'Main Street Market',
      photo: File(saved.photoPath),
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
    expect(await File(replaced.photoPath).readAsBytes(), _gif);
    expect(await File(saved.photoPath).exists(), isFalse);
    expect((await store.load()).single.code, isNull);

    await store.delete(replaced);
    expect(await store.load(), isEmpty);
    expect(await File(replaced.photoPath).exists(), isFalse);
  });

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
      {'code': '0007'},
    ]) {
      await share.writeAsString(jsonEncode({...data, ...changes}));
      await expectLater(
        store.importCard(share.openRead()),
        throwsFormatException,
      );
    }
    expect(await store.load(), isEmpty);
  });
}
