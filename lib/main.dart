import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'app_theme.dart';
import 'card_pages.dart';
import 'card_store.dart';
import 'l10n/app_localizations.dart';
import 'nearby_merge_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(LoyaltyPocketApp(initialTheme: await AppThemePreference.read()));
}

class LoyaltyPocketApp extends StatefulWidget {
  const LoyaltyPocketApp({super.key, this.initialTheme = ThemeMode.system});

  final ThemeMode initialTheme;

  @override
  State<LoyaltyPocketApp> createState() => _LoyaltyPocketAppState();
}

class _LoyaltyPocketAppState extends State<LoyaltyPocketApp> {
  late ThemeMode _themeMode = widget.initialTheme;

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    await AppThemePreference.write(mode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Loyalty Pocket',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _themeMode,
      home: _WalletPage(themeMode: _themeMode, onThemeChanged: _setThemeMode),
    );
  }
}

enum _ImportKind { file, photos }

class _WalletPage extends StatefulWidget {
  const _WalletPage({required this.themeMode, required this.onThemeChanged});

  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeChanged;

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
          await _reviewPhotos(files);
        } else if (result.exception != null) {
          _notice((l10n) => l10n.photoRecoveryFailed);
        }
      } catch (_) {
        _notice((l10n) => l10n.photoRecoveryFailed);
      }
    }
  }

  void _notice(String Function(AppLocalizations) message) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message(l10n))));
  }

  Future<bool> _addCard({XFile? photo}) async {
    final store = await _store;
    if (!mounted) return false;
    final card = await Navigator.of(context).push<LoyaltyCard>(
      MaterialPageRoute(
        builder: (_) => EditCardPage(store: store, recoveredPhoto: photo),
      ),
    );
    if (card != null && mounted) await _load();
    return card != null;
  }

  Future<void> _reviewPhotos(List<XFile> photos) async {
    for (final photo in photos) {
      if (!mounted || !await _addCard(photo: photo)) break;
    }
  }

  Future<void> _importPhotos() async {
    setState(() => _importing = true);
    try {
      final photos = await ImagePicker().pickMultiImage(
        requestFullMetadata: false,
      );
      await _reviewPhotos(photos);
    } catch (_) {
      _notice((l10n) => l10n.photoImportFailed);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _importCard() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _importing = true);
    try {
      final json = XTypeGroup(
        label: l10n.cardFileType,
        extensions: const ['json'],
        mimeTypes: const ['application/json'],
        uniformTypeIdentifiers: const ['public.json'],
      );
      final files = await openFiles(acceptedTypeGroups: [json]);
      if (files.isEmpty || !mounted) return;
      final store = await _store;
      var imported = 0;
      var invalid = 0;
      var duplicateCount = 0;
      final duplicates = <String, LoyaltyCard>{};
      for (final file in files) {
        try {
          await store.importCard(file.openRead());
          imported++;
        } on DuplicateCardException catch (error) {
          duplicateCount++;
          duplicates[error.existing.id] = error.existing;
        } on FormatException {
          invalid++;
        } catch (_) {
          // A file that could not be read does not prevent the rest from loading.
        }
      }
      final failed = files.length - imported - duplicateCount;
      if (imported > 0) {
        await _load();
        _notice(
          (l10n) => failed == 0
              ? l10n.cardsImported(imported)
              : l10n.cardsImportedPartial(imported, failed),
        );
      } else if (failed > 0) {
        _notice(
          (l10n) => invalid == failed
              ? l10n.invalidCardFile
              : l10n.cardFileOpenFailed,
        );
      }
      if (mounted && duplicates.isNotEmpty) {
        await showDuplicateCardsDialog(context, duplicates.values.toList());
      }
    } catch (_) {
      _notice((l10n) => l10n.cardFileOpenFailed);
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

  Future<void> _editNote(LoyaltyCard card) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _CardNoteDialog(card: card),
    );
    if (!mounted || note == null) return;
    try {
      await (await _store).updateNote(card, note);
      if (mounted) await _load();
    } catch (_) {
      _notice((l10n) => l10n.noteSaveFailed);
    }
  }

  Future<void> _openNearbyMerge() async {
    final store = await _store;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => NearbyMergePage(store: store)),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cards = _cards;
    final ready = cards != null && !_loadFailed && !_importing;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Loyalty Pocket',
          style: TextStyle(fontWeight: FontWeight.w800),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          AppThemeButton(
            mode: widget.themeMode,
            onChanged: (mode) async {
              try {
                await widget.onThemeChanged(mode);
              } catch (_) {
                _notice((l10n) => l10n.themeSaveFailed);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.devices),
            tooltip: l10n.nearbyMergeTitle,
            onPressed: ready ? _openNearbyMerge : null,
          ),
          PopupMenuButton<_ImportKind>(
            tooltip: l10n.importCards,
            icon: const Icon(Icons.file_download_outlined),
            enabled: ready,
            onSelected: (kind) {
              switch (kind) {
                case _ImportKind.file:
                  _importCard();
                case _ImportKind.photos:
                  _importPhotos();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _ImportKind.file,
                child: Text(l10n.importSharedCard),
              ),
              PopupMenuItem(
                value: _ImportKind.photos,
                child: Text(l10n.importCardPhotos),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
          children: [
            if (_loadFailed)
              ListTile(
                title: Text(l10n.walletLoadFailed),
                trailing: TextButton(
                  onPressed: () {
                    _store = _openStore();
                    _load(recoverPhoto: Platform.isAndroid);
                  },
                  child: Text(l10n.retry),
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
                        l10n.noCards,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(l10n.emptyWallet),
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: _importCard,
                        icon: const Icon(Icons.file_download_outlined),
                        label: Text(l10n.importSharedCard),
                      ),
                      TextButton.icon(
                        onPressed: _importPhotos,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: Text(l10n.importCardPhotos),
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
                    isThreeLine: card.note != null,
                    leading: switch (card.photoPath) {
                      final path? => ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(path),
                          width: 54,
                          height: 44,
                          fit: BoxFit.cover,
                          cacheWidth: 160,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.credit_card_outlined),
                        ),
                      ),
                      null => const SizedBox(
                        width: 54,
                        child: Icon(Icons.credit_card_outlined),
                      ),
                    },
                    title: Text(card.name),
                    subtitle: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          card.format?.localizedLabel(l10n) ??
                              (card.code == null
                                  ? l10n.cardOriginalPhoto
                                  : l10n.cardMembershipNumber),
                        ),
                        if (card.note case final note?)
                          Text(
                            note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                    trailing: IconButton(
                      tooltip: card.note == null
                          ? l10n.addCardNote(card.name)
                          : l10n.editCardNote(card.name),
                      icon: const Icon(Icons.edit_note),
                      onPressed: () => _editNote(card),
                    ),
                    onTap: () => _openCard(card),
                  ),
                ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: ready ? _addCard : null,
        icon: const Icon(Icons.add),
        label: Text(l10n.addCard),
      ),
    );
  }
}

class _CardNoteDialog extends StatefulWidget {
  const _CardNoteDialog({required this.card});

  final LoyaltyCard card;

  @override
  State<_CardNoteDialog> createState() => _CardNoteDialogState();
}

class _CardNoteDialogState extends State<_CardNoteDialog> {
  late final _controller = TextEditingController(text: widget.card.note);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.cardNoteTitle(widget.card.name)),
      scrollable: true,
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 3,
        maxLength: CardStore.maxNoteLength,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: l10n.cardNoteOptional),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cardCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.saveCardNote),
        ),
      ],
    );
  }
}
