# Loyalty Pocket

Loyalty Pocket is an offline wallet for supermarket, retail, and other loyalty cards. It keeps the original card photo and can display a separate, high-contrast barcode for checkout.

## Add and use a card

1. Tap **Add card**, then **Take photo** or **Choose photo**. When taking a photo, place the full barcode inside the camera guide and tap the shutter.
2. Give the card a name. When the photo contains one readable barcode, the app fills in its value and format. If it misses the barcode, tap **Scan barcode** or enter the number manually. You can also save a photo-only card.
3. Open the saved card at checkout. The barcode appears at the top of the screen. Tap **View original photo** to see the full image and pinch to zoom.

Use the note icon next to a card to add or change an optional short note. When a barcode is already saved, Loyalty Pocket shows the existing card and its note.

Cards are listed A–Z by default. Use **Sort cards** to put the most used cards first. Each time you open a card counts as one use.

The app raises display brightness to maximum while the checkout barcode is visible. Regular brightness returns when you scroll the code out of view, open the original photo or leave the app. Cards and photos are stored in the app's local storage.

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

Open **Nearby Sync** from the devices icon. Choose **Invite a device** on one phone and **Scan an invitation** on the other. An invitation expires after five minutes, when it is used or when you close it. The same group can sync automatically over a shared Wi-Fi network or when the devices come within Bluetooth range. A phone can pass cards it previously received to other group members.

Tap **Sync now** to look for group members immediately, even when automatic sync is off. If Bluetooth is off, Android asks you to confirm turning it on. On iPhone and iPad, turn it on in Settings if prompted. Shared Wi-Fi can carry a sync while Bluetooth is off.

**Recent syncs** shows the device name, time, and numbers of cards sent and received. Each phone keeps its own details and photos for cards it already has. If a transfer breaks, the next sync skips cards that were already saved. A card deleted locally can be received again from a group member that still has it.

Android shows a notification while its background sync service is active. On iPhone and iPad, the system controls when background sync can run. For mixed groups the iPhone can discover the Android phone’s Bluetooth advertisement. A force-quit or a reboot may require you to open the app again.

**Merge manually over Wi-Fi** is available on the same screen. Connect the phones to the same Wi-Fi network and open that option on each. Select the peers on one phone and approve the matching verification code.

### Verify nearby merge before a release

Run `flutter test` for every change. The Bluetooth protocol tests exercise four-wallet relay, original photo bytes, duplicate local notes, one-time pairing, and interruption. The Wi-Fi tests run independent wallets over real local connections.

The same suite simulates 15 Android phone, iPhone, Android tablet, and iPad profiles with different packet sizes. It runs the app’s encrypted sync protocol, packet framing, and card storage with simulated Bluetooth links. The scenario splits the group, drops a transfer mid-photo, moves devices in and out of range, and brings the group together. It verifies that all 15 wallets converge, both original photos match byte for byte, local notes survive, and repeat syncs send no cards. Run this suite directly with `flutter test test/bluetooth_sync_protocol_test.dart`.

Android emulators with API 31 or later can exercise the native Bluetooth path. Keep the physical device checks below for radio behavior, background scheduling, and mixed Android–Apple compatibility.

Verify Bluetooth with physical Android and Apple devices and synthetic cards before a stable release. Run the locked-screen test for Android-to-Android, Android-to-Apple, and Apple-to-Apple, covering iPhone and iPad.

1. Pair devices with one-time invitations. Add a common card with a different note on each phone and one unique card with an original photo.
2. Turn Wi-Fi and mobile data off in Settings, with Bluetooth on. While the phones are out of range, put Loyalty Pocket in the background and lock both screens.
3. Bring the phones into range without reopening Loyalty Pocket. Verify that **Recent syncs** shows the correct peer and counts and that the original photo opens on the receiving phone.
4. Repeat with four members and stagger their encounters so that a card crosses at least two links. Verify that common cards retain their local notes and a subsequent encounter reports the wallets are up to date.
5. Interrupt a photo transfer by separating the phones. Bring them back together and verify that the next sync finishes the missing card without duplicating cards already saved.

For automatic Wi-Fi sync, pair devices on the same network, turn Bluetooth off on both and add a test card. Verify that the other device receives it without tapping **Sync now**. Turn off automatic sync on one device, add another card there, and tap **Sync now**. Verify that Wi-Fi can finish the transfer if you decline the Android Bluetooth prompt. Confirm the switch stays off after the attempt. Turn both radios on and repeat with a shared card to verify that only one copy is saved.

For manual Wi-Fi regressions, also install the release APK on three Android emulators connected to the same virtual Wi-Fi.

1. On each emulator, add a card with the same barcode and a different note. Add one unique card per emulator and include an original photo on one of them.
2. Open **Nearby Sync → Merge manually over Wi-Fi** on all three. Select one peer, decline on that peer, and verify that both wallets still contain only their original test cards.
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
