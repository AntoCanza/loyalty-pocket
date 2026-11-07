import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'card_pages.dart';
import 'card_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LoyaltyPocketApp());
}

const _ink = Color(0xFF123B34);
const _canvas = Color(0xFFF3F6F0);
const _mint = Color(0xFFBCEED1);

class LoyaltyPocketApp extends StatelessWidget {
  const LoyaltyPocketApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Loyalty Pocket',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _ink),
        scaffoldBackgroundColor: _canvas,
        appBarTheme: const AppBarTheme(
          backgroundColor: _canvas,
          foregroundColor: _ink,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const _WalletPage(),
    );
  }
}

class _WalletPage extends StatefulWidget {
  const _WalletPage();

  @override
  State<_WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<_WalletPage> {
  late Future<CardStore> _store;
  List<LoyaltyCard>? _cards;
  bool _loadFailed = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _store = _openStore();
    unawaited(_load(recoverPhoto: Platform.isAndroid));
  }

  Future<CardStore> _openStore() async {
    final documents = await getApplicationDocumentsDirectory();
    return CardStore(
      Directory('${documents.path}${Platform.pathSeparator}cards'),
    );
  }

  Future<void> _load({bool recoverPhoto = false}) async {
    try {
      final cards = await (await _store).load();
      if (!mounted) return;
      setState(() {
        _cards = cards;
        _loadFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
      return;
    }
    if (recoverPhoto) {
      try {
        final result = await ImagePicker().retrieveLostData();
        final files = result.files;
        if (mounted && files != null && files.isNotEmpty) {
          await _addCard(photo: files.first);
        } else if (result.exception != null) {
          _notice('The interrupted photo capture could not be restored.');
        }
      } catch (_) {
        _notice('The interrupted photo capture could not be restored.');
      }
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addCard({XFile? photo}) async {
    final store = await _store;
    if (!mounted) return;
    final card = await Navigator.of(context).push<LoyaltyCard>(
      MaterialPageRoute(
        builder: (_) => EditCardPage(store: store, recoveredPhoto: photo),
      ),
    );
    if (card != null && mounted) await _load();
  }

  Future<void> _importCard() async {
    setState(() => _importing = true);
    try {
      const json = XTypeGroup(
        label: 'Loyalty Pocket card',
        extensions: ['json'],
        mimeTypes: ['application/json'],
        uniformTypeIdentifiers: ['public.json'],
      );
      final file = await openFile(acceptedTypeGroups: [json]);
      if (file == null || !mounted) return;
      await (await _store).importCard(file.openRead());
      await _load();
      _notice('Card imported.');
    } on FormatException catch (error) {
      _notice(error.message);
    } catch (_) {
      _notice('Could not open the card file. Please try again.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _openCard(LoyaltyCard card) async {
    final store = await _store;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CardPage(store: store, card: card),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cards = _cards;
    final ready = cards != null && !_loadFailed && !_importing;
    final count = cards?.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Loyalty Pocket',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Import shared card',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: ready ? _importCard : null,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: const LinearGradient(
                  colors: [_ink, Color(0xFF216150)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.account_balance_wallet_outlined,
                    color: _mint,
                    size: 32,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Your card wallet',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$count ${count == 1 ? 'card' : 'cards'} stored on this device',
                    style: const TextStyle(color: _mint),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'Saved cards',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (_loadFailed)
              ListTile(
                title: const Text('Could not load your wallet'),
                trailing: TextButton(
                  onPressed: () {
                    _store = _openStore();
                    _load(recoverPhoto: Platform.isAndroid);
                  },
                  child: const Text('Retry'),
                ),
              )
            else if (cards == null || _importing)
              const LinearProgressIndicator()
            else if (cards.isEmpty)
              Card(
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'No cards yet',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Take a photo of a loyalty card or import a card '
                        'someone shared with you.',
                      ),
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: _importCard,
                        icon: const Icon(Icons.file_download_outlined),
                        label: const Text('Import shared card'),
                      ),
                    ],
                  ),
                ),
              )
            else
              for (final card in cards)
                Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 8),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(card.photoPath),
                        width: 54,
                        height: 44,
                        fit: BoxFit.cover,
                        cacheWidth: 160,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.credit_card_outlined),
                      ),
                    ),
                    title: Text(card.name),
                    subtitle: Text(card.format?.label ?? 'Original photo'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openCard(card),
                  ),
                ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: ready ? _addCard : null,
        icon: const Icon(Icons.add),
        label: const Text('Add card'),
      ),
    );
  }
}
