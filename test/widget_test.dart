import 'dart:convert';
import 'dart:io';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/card_pages.dart';
import 'package:loyalty_pocket/card_store.dart';

void main() {
  testWidgets('shows the checkout code and opens the original photo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('loyalty-checkout-');
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
        home: CardPage(store: CardStore(directory), card: card),
      ),
    );

    expect(find.text('Grocery rewards'), findsOneWidget);
    expect(find.byType(BarcodeWidget), findsOneWidget);
    expect(find.text('0012345678'), findsOneWidget);

    final original = find.text('View original photo');
    await tester.ensureVisible(original);
    await tester.tap(original);
    await tester.pumpAndSettle();

    expect(find.text('Original photo'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.widget<Image>(find.byType(Image)).image, FileImage(photo));
  });
}
