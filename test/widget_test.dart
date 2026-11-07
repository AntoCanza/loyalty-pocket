import 'dart:convert';
import 'dart:io';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/card_pages.dart';
import 'package:loyalty_pocket/card_store.dart';
import 'package:loyalty_pocket/l10n/app_localizations.dart';

void main() {
  for (final (language, viewPhoto, photoTitle) in const [
    ('en', 'View original photo', 'Original photo'),
    ('it', 'Vedi foto originale', 'Foto originale'),
  ]) {
    testWidgets('shows the checkout code and original photo in $language', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CardPage(store: CardStore(directory), card: card),
        ),
      );

      expect(find.text('Grocery rewards'), findsOneWidget);
      expect(find.byType(BarcodeWidget), findsOneWidget);
      expect(find.text('0012345678'), findsOneWidget);

      final original = find.text(viewPhoto);
      await tester.ensureVisible(original);
      await tester.tap(original);
      await tester.pumpAndSettle();

      expect(find.text(photoTitle), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.widget<Image>(find.byType(Image)).image, FileImage(photo));
    });
  }

  testWidgets('shows the exact membership number when its format is unknown', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('loyalty-number-');
    addTearDown(() => directory.deleteSync(recursive: true));
    const card = LoyaltyCard(
      id: 'test',
      name: 'Grocery rewards',
      photoPath: null,
      code: '0001234567890',
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('it'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CardPage(store: CardStore(directory), card: card),
      ),
    );

    expect(find.text('Numero della carta'), findsOneWidget);
    expect(find.text('0001234567890'), findsOneWidget);
    expect(find.byType(BarcodeWidget), findsNothing);
    expect(find.text('Aggiungi foto originale'), findsOneWidget);
  });
}
