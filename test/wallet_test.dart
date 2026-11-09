import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;
import 'package:loyalty_pocket/card_camera_page.dart';
import 'package:loyalty_pocket/card_store.dart';
import 'package:loyalty_pocket/main.dart';
import 'package:mobile_scanner/mobile_scanner.dart' show BarcodeFormat;

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');
const _imagePicker = MethodChannel('plugins.flutter.io/image_picker');
const _camera = MethodChannel('plugins.flutter.io/camera');
const _scanner = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');

void main() {
  testWidgets('shows progress while retrying a failed wallet load', (
    tester,
  ) async {
    final documents = Directory.systemTemp.createTempSync('loyalty-wallet-');
    addTearDown(() => documents.deleteSync(recursive: true));
    final store = CardStore(Directory('${documents.path}/cards'));
    await tester.runAsync(
      () => store.save(name: 'Recovered card', code: '1001', photo: null),
    );

    final available = Completer<String>();
    var attempts = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_pathProvider, (_) {
      attempts++;
      if (attempts == 1) throw PlatformException(code: 'unavailable');
      return available.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_pathProvider, null));

    await tester.pumpWidget(const LoyaltyPocketApp());
    final retry = find.text('Retry');
    await _waitFor(tester, retry);
    await tester.tap(retry);
    await tester.pump();

    expect(attempts, 2);
    expect(retry, findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    available.complete(documents.path);
    await _waitFor(tester, find.text('Recovered card'));
    expect(attempts, 2);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('sorts by name or use and remembers the choice', (tester) async {
    final documents = Directory.systemTemp.createTempSync('loyalty-wallet-');
    addTearDown(() => documents.deleteSync(recursive: true));
    final store = CardStore(Directory('${documents.path}/cards'));
    await tester.runAsync(() async {
      await store.save(name: 'Zeta', code: '002', photo: null);
      await store.save(name: 'Alpha', code: '001', photo: null);
    });

    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      _pathProvider,
      (_) async => documents.path,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(_pathProvider, null));

    final alpha = find.text('Alpha');
    final zeta = find.text('Zeta');
    final sort = find.text('Sort cards');
    await tester.pumpWidget(const LoyaltyPocketApp());
    await _waitFor(tester, alpha);
    expect(tester.getTopLeft(alpha).dy, lessThan(tester.getTopLeft(zeta).dy));

    await tester.tap(zeta);
    await _waitFor(tester, find.text('002'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add a note for Alpha'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'For groceries');
    await tester.tap(find.text('Save note'));
    await _waitFor(tester, find.byTooltip('Edit the note for Alpha'));
    expect(find.text('For groceries'), findsOneWidget);

    await tester.tapAt(
      Offset(
        tester.getCenter(find.byType(ListView)).dx,
        tester.getCenter(sort).dy,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<CardSortOrder>, 'Most used'),
    );
    final mostUsed = find.byWidgetPredicate(
      (widget) =>
          widget is PopupMenuButton<CardSortOrder> &&
          widget.initialValue == CardSortOrder.mostUsed &&
          widget.enabled,
    );
    await _waitFor(tester, mostUsed);
    expect(tester.getTopLeft(zeta).dy, lessThan(tester.getTopLeft(alpha).dy));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const LoyaltyPocketApp());
    await _waitFor(tester, mostUsed);
    expect(tester.getTopLeft(zeta).dy, lessThan(tester.getTopLeft(alpha).dy));
    final cards = await tester.runAsync(store.load);
    expect(cards?.map((card) => card.useCount), [0, 1]);
  });

  testWidgets(
    'opens the camera guide and detects the format of a chosen photo',
    (tester) async {
      const code = '0001234567895';
      final documents = Directory.systemTemp.createTempSync('loyalty-wallet-');
      addTearDown(() => documents.deleteSync(recursive: true));
      final photo = File('${documents.path}/original.png')
        ..writeAsBytesSync(_pixel);
      final store = CardStore(Directory('${documents.path}/cards'));
      final messenger = tester.binding.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        SystemChannels.lifecycle.name,
        const StringCodec().encodeMessage(AppLifecycleState.resumed.toString()),
        null,
      );
      messenger.setMockMethodCallHandler(
        _pathProvider,
        (_) async => documents.path,
      );
      var cameraChecks = 0;
      messenger.setMockMethodCallHandler(_camera, (call) async {
        expect(call.method, 'availableCameras');
        cameraChecks++;
        return <Object>[];
      });
      messenger.setMockMethodCallHandler(_imagePicker, (call) async {
        expect(call.method, 'pickImage');
        expect(call.arguments['source'], ImageSource.gallery.index);
        expect(call.arguments['imageQuality'], isNull);
        expect(call.arguments['maxWidth'], isNull);
        expect(call.arguments['maxHeight'], isNull);
        return photo.path;
      });
      messenger.setMockMethodCallHandler(_scanner, (call) async {
        expect(call.method, 'analyzeImage');
        expect(call.arguments['filePath'], photo.path);
        return {
          'data': [
            {'format': BarcodeFormat.ean13.rawValue, 'rawValue': code},
          ],
        };
      });
      addTearDown(() {
        for (final channel in [
          _pathProvider,
          _camera,
          _imagePicker,
          _scanner,
        ]) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });

      await tester.pumpWidget(const LoyaltyPocketApp());
      final addCard = find.byWidgetPredicate(
        (widget) => widget is FloatingActionButton && widget.onPressed != null,
      );
      await _waitFor(tester, addCard);
      await tester.tap(addCard);
      await tester.pumpAndSettle();

      final format = find.byType(DropdownButtonFormField<CardCodeFormat>);
      expect(
        tester
            .widget<DropdownButtonFormField<CardCodeFormat>>(format)
            .initialValue,
        isNull,
      );
      await tester.tap(find.text('Take photo'));
      await tester.pumpAndSettle();
      expect(find.byType(CardCameraPage), findsOneWidget);
      expect(cameraChecks, 1);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Choose photo'));
      await _waitFor(tester, find.widgetWithText(TextFormField, code));
      final decodedPhoto = find.byWidgetPredicate(
        (widget) => widget is RawImage && widget.image != null,
      );
      await _waitFor(tester, decodedPhoto);
      expect(
        tester
            .widget<DropdownButtonFormField<CardCodeFormat>>(format)
            .initialValue,
        CardCodeFormat.ean13,
      );

      final name = find.widgetWithText(TextFormField, 'Card name');
      await tester.ensureVisible(name);
      await tester.enterText(name, 'Supermarket rewards');
      final save = find.text('Save card');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await _waitFor(
        tester,
        find.byTooltip('Add a note for Supermarket rewards'),
      );
      await _waitFor(tester, decodedPhoto);

      final cards = await tester.runAsync(store.load);
      final saved = cards!.single;
      expect(saved.code, code);
      expect(saved.format, CardCodeFormat.ean13);
      expect(saved.photoPath, isNot(photo.path));
      expect(File(saved.photoPath!).readAsBytesSync(), _pixel);
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.imageCache
        ..clear()
        ..clearLiveImages();
    },
  );

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
    expect(find.text('My checkout note'), findsOneWidget);
    expect(find.text('Card number'), findsNothing);
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
    expect(find.text('Code 128'), findsNothing);

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
    expect(newCard.format, CardCodeFormat.code128);
    expect(newCard.note, 'Use at self-checkout');
    expect(File(newCard.photoPath!).readAsBytesSync(), _pixel);
  });
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  // Wallet file operations run in real time, outside the widget test clock.
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 5)) {
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
