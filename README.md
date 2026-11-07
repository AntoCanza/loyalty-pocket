# Loyalty Pocket

Loyalty Pocket is an offline wallet for supermarket, retail, and other loyalty cards. It keeps the original card photo and can display a separate, high-contrast barcode for checkout.

## Add and use a card

1. Tap **Add card**, then **Take photo** or **Choose photo**. Capture the side with the barcode if you want the app to detect it automatically.
2. Give the card a name. If the photo scan misses the barcode, tap **Scan barcode** or enter the value and select its format. You can also save a photo-only card.
3. Open the saved card at checkout. The barcode appears at the top of the screen. Tap **View original photo** to see the full image and pinch to zoom.

Use the note icon next to a card to add or change an optional short note. When a barcode is already saved, Loyalty Pocket shows the existing card and its note.

The app raises display brightness to maximum while it is active. Your regular brightness returns when you leave it. Cards and photos are stored in the app's local storage.

The interface is available in English and Italian and follows your device language. On devices with per-app language settings, you can select English or Italian for Loyalty Pocket.

The appearance menu offers **Use device theme**, **Light**, and **Dark**. The app remembers your choice and displays barcodes on a white background.

To move cards from another wallet, take a screenshot of each loyalty barcode, then open **Import cards → Import photos or screenshots**. Select the images together. Loyalty Pocket looks for a barcode in each image and lets you name and review each card before saving it. Acknowledge the duplicate notice to move on to the next photo.

If only a membership number is available, you can save it and add a photo later. The app displays the number by itself when its barcode format is unknown.

## Share a card

1. Open the card and tap **Share card**.
2. Choose **Quick Share** on Android or **AirDrop** on iPhone, where available. The shared file contains the card name, barcode value and format, and any original photo and note.
3. On the receiving phone, accept the file and save it to **Downloads** or **Files** if prompted. In Loyalty Pocket, tap the import icon and choose one or more received `.loyalty-card.json` files.

Any file transfer method that preserves the file can also be used to move a card between Android and iPhone.

## Merge nearby wallets

Connect the devices to the same Wi-Fi network and open **Nearby merge** on each device. On one device, select the other devices and start the merge. Check that the verification code matches before approving on both screens. The encrypted transfer takes place on the local network.

Each device receives the cards it is missing and keeps its own details and photos for the cards it already has.

### Verify nearby merge before a release

Run `flutter test` for every change. The GitHub checks run the same suite. The merge tests run three independent wallets over real local connections. They verify pairing, missing cards, original photo bytes, conflicting local notes, repeat merges, and recovery when a single card fails to copy.

Before releasing a merge change, also install the release APK on three Android emulators connected to the same virtual Wi-Fi. Use only test cards.

1. On each emulator, add a card with the same barcode and a different note. Add one unique card per emulator and include an original photo on one of them.
2. Open **Nearby merge** on all three. Select one peer, decline on that peer, and verify that both wallets still contain only their original test cards.
3. Select both other devices from one emulator. Verify each pair shows the same code and approve on both devices.
4. Confirm that all three wallets now have four cards, that each retained its own note on the common card, and that the transferred photo opens on another device.
5. Repeat the merge and verify that it reports zero cards received and zero copies sent.

## Build locally

Use Flutter 3.35.2 and Dart 3.9. Android requires JDK 17 and Android SDK 36. iPhone builds require macOS and Xcode. The app targets Android 7.0 or later and iOS 13 or later.

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

Run `flutter build apk --release` to produce an Android preview APK. The preview uses Flutter's default debug signing key. A store build needs its own signing configuration.
