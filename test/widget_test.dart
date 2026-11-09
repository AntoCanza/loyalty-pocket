import 'dart:convert';
import 'dart:io';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/card_pages.dart';
import 'package:loyalty_pocket/card_store.dart';
import 'package:loyalty_pocket/l10n/app_localizations.dart';

const _brightness = MethodChannel('loyalty_pocket/screen_brightness');

void main() {
  for (final (language, viewPhoto, photoTitle) in const [
    ('en', 'View original photo', 'Original photo'),
    ('it', 'Vedi foto originale', 'Foto originale'),
  ]) {
    testWidgets('shows the checkout code and original photo in $language', (
      tester,
    ) async {
      _setViewport(tester, const Size(390, 844));
      final brightness = await _recordBrightness(tester);
      final directory = Directory.systemTemp.createTempSync(
        'loyalty-checkout-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final photo = File('${directory.path}/card.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
          ),
        );
      final card = LoyaltyCard(
        id: 'test',
        name: 'Grocery rewards',
        photoPath: photo.path,
        code: '0012345678',
        format: CardCodeFormat.code128,
      );
      await _pumpCard(tester, directory, card, locale: Locale(language));

      expect(find.text('Grocery rewards'), findsOneWidget);
      expect(find.byType(BarcodeWidget), findsOneWidget);
      expect(find.text('0012345678'), findsOneWidget);
      expect(brightness.lastOrNull, isTrue);

      final original = find.text(viewPhoto);
      await tester.ensureVisible(original);
      await tester.tap(original);
      await tester.pumpAndSettle();

      expect(find.text(photoTitle), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.widget<Image>(find.byType(Image)).image, FileImage(photo));
      expect(brightness.lastOrNull, isFalse);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(brightness.lastOrNull, isTrue);
    });
  }

  testWidgets('shows the exact membership number when its format is unknown', (
    tester,
  ) async {
    final brightness = await _recordBrightness(tester);
    final directory = Directory.systemTemp.createTempSync('loyalty-number-');
    addTearDown(() => directory.deleteSync(recursive: true));
    const card = LoyaltyCard(
      id: 'test',
      name: 'Grocery rewards',
      photoPath: null,
      code: '0001234567890',
    );
    await _pumpCard(tester, directory, card, locale: const Locale('it'));

    expect(find.text('Numero della carta'), findsOneWidget);
    expect(find.text('0001234567890'), findsOneWidget);
    expect(find.byType(BarcodeWidget), findsNothing);
    expect(find.text('Aggiungi foto originale'), findsOneWidget);
    expect(brightness, isNot(contains(true)));
  });

  testWidgets('keeps normal brightness when the barcode cannot be rendered', (
    tester,
  ) async {
    final brightness = await _recordBrightness(tester);
    final directory = Directory.systemTemp.createTempSync('loyalty-invalid-');
    addTearDown(() => directory.deleteSync(recursive: true));
    const card = LoyaltyCard(
      id: 'test',
      name: 'Grocery rewards',
      photoPath: null,
      code: 'invalid EAN',
      format: CardCodeFormat.ean13,
    );
    await _pumpCard(tester, directory, card);

    expect(find.text('invalid EAN'), findsOneWidget);
    expect(brightness, isNot(contains(true)));
  });

  testWidgets('restores normal brightness on background or scroll', (
    tester,
  ) async {
    _setViewport(tester, const Size(390, 350));
    final brightness = await _recordBrightness(tester);
    final directory = Directory.systemTemp.createTempSync('loyalty-scroll-');
    addTearDown(() => directory.deleteSync(recursive: true));
    const card = LoyaltyCard(
      id: 'test',
      name: 'Grocery rewards',
      photoPath: null,
      code: '0012345678',
      format: CardCodeFormat.code128,
      note: 'Store locations\nNorth\nEast\nWest\nSouth\nMall\nAirport\nStation',
    );
    await _pumpCard(tester, directory, card);
    expect(brightness.lastOrNull, isTrue);

    await _setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    expect(brightness.lastOrNull, isFalse);

    await _setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(brightness.lastOrNull, isTrue);

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(brightness.lastOrNull, isFalse);

    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(brightness.lastOrNull, isTrue);
  });
}

Future<void> _setLifecycle(WidgetTester tester, AppLifecycleState state) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.lifecycle.name,
    const StringCodec().encodeMessage(state.toString()),
    null,
  );
}

Future<List<bool>> _recordBrightness(WidgetTester tester) async {
  await _setLifecycle(tester, AppLifecycleState.resumed);
  final changes = <bool>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_brightness, (call) async {
    expect(call.method, 'setBarcodeVisible');
    changes.add(call.arguments as bool);
    return null;
  });
  addTearDown(() async {
    await _setLifecycle(tester, AppLifecycleState.resumed);
    messenger.setMockMethodCallHandler(_brightness, null);
  });
  return changes;
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpCard(
  WidgetTester tester,
  Directory directory,
  LoyaltyCard card, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CardPage(store: CardStore(directory), card: card),
    ),
  );
  await tester.pumpAndSettle();
}
