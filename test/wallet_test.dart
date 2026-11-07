import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/card_store.dart';
import 'package:loyalty_pocket/main.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');
const _imagePicker = MethodChannel('plugins.flutter.io/image_picker');
const _scanner = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');

void main() {
  testWidgets('skips a duplicate photo and saves the next card in a batch', (
    tester,
  ) async {
    final documents = Directory.systemTemp.createTempSync('loyalty-wallet-');
    addTearDown(() => documents.deleteSync(recursive: true));
    final store = CardStore(Directory('${documents.path}/cards'));
    await tester.runAsync(
      () => store.save(
        name: 'Existing grocery card',
        code: 'DUPLICATE-001',
        note: 'My checkout note',
        photo: null,
      ),
    );

    final photos = [
      for (final name in ['existing.png', 'new.png'])
        (File('${documents.path}/$name')..writeAsBytesSync(_pixel)).path,
    ];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      _pathProvider,
      (_) async => documents.path,
    );
    messenger.setMockMethodCallHandler(_imagePicker, (call) async {
      expect(call.method, 'pickMultiImage');
      return photos;
    });
    messenger.setMockMethodCallHandler(_scanner, (call) async {
      expect(call.method, 'analyzeImage');
      return {
        'data': [
          {
            'format': 1,
            'rawValue': call.arguments['filePath'] == photos.first
                ? 'DUPLICATE-001'
                : 'NEW-001',
          },
        ],
      };
    });
    addTearDown(() {
      for (final channel in [_pathProvider, _imagePicker, _scanner]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });

    await tester.pumpWidget(const LoyaltyPocketApp());
    await _waitFor(tester, find.text('Existing grocery card'));
    await tester.tap(find.byTooltip('Import cards'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import photos or screenshots'));
    await _waitFor(tester, find.text('Card already registered'));
    expect(find.text('Existing grocery card'), findsOneWidget);
    expect(find.text('My checkout note'), findsOneWidget);
    await tester.tap(find.text('OK'));

    final newCode = find.widgetWithText(TextFormField, 'NEW-001');
    await _waitFor(tester, newCode);
    final name = find.widgetWithText(TextFormField, 'Card name');
    await tester.ensureVisible(name);
    await tester.enterText(name, 'New grocery card');
    final save = find.text('Save card');
    await tester.ensureVisible(save);
    await tester.tap(save);
    final addNote = find.byTooltip('Add a note for New grocery card');
    await _waitFor(tester, addNote);
    expect(find.text('Existing grocery card'), findsOneWidget);

    await tester.tap(addNote);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Use at self-checkout');
    await tester.tap(find.text('Save note'));
    await _waitFor(
      tester,
      find.byTooltip('Edit the note for New grocery card'),
    );
    expect(find.text('Use at self-checkout'), findsOneWidget);

    final cards = await tester.runAsync(store.load);
    expect(
      cards!.map((card) => card.code),
      unorderedEquals(['DUPLICATE-001', 'NEW-001']),
    );
    final newCard = cards.singleWhere((card) => card.code == 'NEW-001');
    expect(newCard.note, 'Use at self-checkout');
    expect(File(newCard.photoPath!).readAsBytesSync(), _pixel);
  });
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(finder, findsOneWidget);
}

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
);
