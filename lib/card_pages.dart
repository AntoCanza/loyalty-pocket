import 'dart:io';
import 'dart:math' as math;

import 'package:barcode_widget/barcode_widget.dart' as display;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'card_store.dart';

typedef _ScannedCode = ({String value, CardCodeFormat format});

extension on CardCodeFormat {
  static final _codabarWithGuards = RegExp(r'^[ABCDENT*].+[ABCDENT*]$');

  display.Barcode renderer(String value) => switch (this) {
    CardCodeFormat.code128 => display.Barcode.code128(),
    CardCodeFormat.code39 => display.Barcode.code39(),
    CardCodeFormat.code93 => display.Barcode.code93(),
    CardCodeFormat.codabar => display.Barcode.codabar(
      explicitStartStop: _codabarWithGuards.hasMatch(value),
    ),
    CardCodeFormat.ean13 => display.Barcode.ean13(),
    CardCodeFormat.ean8 => display.Barcode.ean8(),
    CardCodeFormat.upcA => display.Barcode.upcA(),
    CardCodeFormat.upcE => display.Barcode.upcE(),
    CardCodeFormat.itf => display.Barcode.itf(),
    CardCodeFormat.qr => display.Barcode.qrCode(),
    CardCodeFormat.dataMatrix => display.Barcode.dataMatrix(),
    CardCodeFormat.pdf417 => display.Barcode.pdf417(),
    CardCodeFormat.aztec => display.Barcode.aztec(),
  };

  bool get square =>
      this == CardCodeFormat.qr ||
      this == CardCodeFormat.dataMatrix ||
      this == CardCodeFormat.aztec;

  bool accepts(String value) {
    if (value.isEmpty || value.length > CardStore.maxCodeLength) return false;
    try {
      renderer(value).verify(value);
      return true;
    } catch (_) {
      return false;
    }
  }
}

Set<_ScannedCode> _readCodes(BarcodeCapture capture) {
  final codes = <_ScannedCode>{};
  for (final code in capture.barcodes) {
    final value = code.rawValue;
    final format = switch (code.format) {
      BarcodeFormat.code128 => CardCodeFormat.code128,
      BarcodeFormat.code39 => CardCodeFormat.code39,
      BarcodeFormat.code93 => CardCodeFormat.code93,
      BarcodeFormat.codabar => CardCodeFormat.codabar,
      BarcodeFormat.ean13 => CardCodeFormat.ean13,
      BarcodeFormat.ean8 => CardCodeFormat.ean8,
      BarcodeFormat.upcA => CardCodeFormat.upcA,
      BarcodeFormat.upcE => CardCodeFormat.upcE,
      BarcodeFormat.itf14 ||
      BarcodeFormat.itf2of5 ||
      BarcodeFormat.itf2of5WithChecksum => CardCodeFormat.itf,
      BarcodeFormat.qrCode => CardCodeFormat.qr,
      BarcodeFormat.dataMatrix => CardCodeFormat.dataMatrix,
      BarcodeFormat.pdf417 => CardCodeFormat.pdf417,
      BarcodeFormat.aztec => CardCodeFormat.aztec,
      _ => null,
    };
    if (value != null && format != null && format.accepts(value)) {
      codes.add((value: value, format: format));
    }
  }
  return codes;
}

class EditCardPage extends StatefulWidget {
  const EditCardPage({
    super.key,
    required this.store,
    this.card,
    this.recoveredPhoto,
  });

  final CardStore store;
  final LoyaltyCard? card;
  final XFile? recoveredPhoto;

  @override
  State<EditCardPage> createState() => _EditCardPageState();
}

class _EditCardPageState extends State<EditCardPage> {
  final _form = GlobalKey<FormState>();
  final _picker = ImagePicker();
  late final _name = TextEditingController(text: widget.card?.name);
  late final _code = TextEditingController(text: widget.card?.code);
  late CardCodeFormat _format = widget.card?.format ?? CardCodeFormat.code128;
  File? _photo;
  bool _working = false;
  String? _photoHint;

  @override
  void initState() {
    super.initState();
    final card = widget.card;
    if (card != null) _photo = File(card.photoPath);
    final recovered = widget.recoveredPhoto;
    if (recovered != null) _usePhoto(recovered);
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _usePhoto(XFile photo) async {
    setState(() => _working = true);
    MobileScannerController? scanner;
    try {
      if (await photo.length() > CardStore.maxPhotoBytes) {
        _notice('Choose a photo that is 20 MB or smaller.');
        return;
      }
      if (!mounted) return;
      setState(() {
        _photo = File(photo.path);
        _photoHint = 'Looking for a barcode in the photo…';
      });
      scanner = MobileScannerController(autoStart: false);
      final capture = await scanner.analyzeImage(photo.path);
      if (!mounted) return;
      final codes = capture == null ? <_ScannedCode>{} : _readCodes(capture);
      setState(() {
        _photoHint = switch (codes.length) {
          0 => 'No barcode found in the photo. You can scan or enter it below.',
          1 => 'Barcode found in the photo.',
          _ => 'Several barcodes found. Scan the one you want below.',
        };
        if (codes.length == 1) _applyCode(codes.single);
      });
    } catch (_) {
      if (!mounted) return;
      if (scanner == null) {
        _notice('Could not open this photo.');
      } else {
        setState(() => _photoHint = 'You can scan or enter the barcode below.');
      }
    } finally {
      await scanner?.dispose();
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _takePhoto(ImageSource source) async {
    setState(() => _working = true);
    try {
      final photo = await _picker.pickImage(source: source);
      if (photo != null && mounted) await _usePhoto(photo);
    } catch (_) {
      _notice(
        'Could not open the camera or photo library. Check your permissions.',
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _applyCode(_ScannedCode code) {
    _code.text = code.value;
    _format = code.format;
  }

  Future<void> _scan() async {
    final result = await Navigator.of(context).push<_ScannedCode>(
      MaterialPageRoute(builder: (_) => const _ScannerPage()),
    );
    if (mounted && result != null) setState(() => _applyCode(result));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final photo = _photo;
    if (photo == null) {
      _notice('Take or choose a photo before saving.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _working = true);
    try {
      final code = _code.text;
      final card = await widget.store.save(
        existing: widget.card,
        name: _name.text,
        photo: photo,
        code: code.isEmpty ? null : code,
        format: code.isEmpty ? null : _format,
      );
      if (mounted) Navigator.of(context).pop(card);
    } on FormatException catch (error) {
      _notice(error.message);
    } catch (_) {
      _notice('Could not save the card. Please try again.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photo;
    final isNew = widget.card == null;
    return PopScope(
      canPop: !_working,
      child: Scaffold(
        appBar: AppBar(title: Text(isNew ? 'Add a card' : 'Edit card')),
        body: SafeArea(
          child: Form(
            key: _form,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_working) const LinearProgressIndicator(),
                  if (isNew) ...[
                    Text(
                      'Original photo',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (photo != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _CardPhoto(photo: photo, height: 172),
                      )
                    else
                      Container(
                        height: 120,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Theme.of(context).colorScheme.surfaceContainer,
                        ),
                        child: const Icon(Icons.add_a_photo_outlined, size: 36),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _working
                              ? null
                              : () => _takePhoto(ImageSource.camera),
                          icon: const Icon(Icons.photo_camera_outlined),
                          label: Text(
                            photo == null ? 'Take photo' : 'Retake photo',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _working
                              ? null
                              : () => _takePhoto(ImageSource.gallery),
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Choose photo'),
                        ),
                      ],
                    ),
                    if (_photoHint case final hint?) ...[
                      const SizedBox(height: 6),
                      Text(hint),
                    ],
                    const SizedBox(height: 22),
                  ],
                  TextFormField(
                    controller: _name,
                    enabled: !_working,
                    maxLength: CardStore.maxNameLength,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Card name',
                      hintText: 'For example, my grocery card',
                    ),
                    validator: (name) => name == null || name.trim().isEmpty
                        ? 'Enter a card name.'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Barcode (optional)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _working ? null : _scan,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan barcode'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<CardCodeFormat>(
                    key: ValueKey(_format),
                    initialValue: _format,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Barcode format',
                    ),
                    items: [
                      for (final format in CardCodeFormat.values)
                        DropdownMenuItem(
                          value: format,
                          child: Text(format.label),
                        ),
                    ],
                    onChanged: _working
                        ? null
                        : (value) => setState(() => _format = value!),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _code,
                    enabled: !_working,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLines: 3,
                    minLines: 1,
                    decoration: const InputDecoration(
                      labelText: 'Barcode value',
                    ),
                    validator: (code) =>
                        code == null || code.isEmpty || _format.accepts(code)
                        ? null
                        : 'Enter a valid ${_format.label} value.',
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _working ? null : _save,
                    child: const Text('Save card'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CardPage extends StatefulWidget {
  const CardPage({super.key, required this.store, required this.card});

  final CardStore store;
  final LoyaltyCard card;

  @override
  State<CardPage> createState() => _CardPageState();
}

class _CardPageState extends State<CardPage> {
  late LoyaltyCard _card = widget.card;
  bool _working = false;

  Future<void> _share(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero) & box.size;
    setState(() => _working = true);
    try {
      final file = await widget.store.exportCard(
        _card,
        await getTemporaryDirectory(),
      );
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json')],
          sharePositionOrigin: origin,
          title: 'Share loyalty card',
        ),
      );
    } catch (_) {
      _notice('Could not share this card. Please try again.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _edit() async {
    final updated = await Navigator.of(context).push<LoyaltyCard>(
      MaterialPageRoute(
        builder: (_) => EditCardPage(store: widget.store, card: _card),
      ),
    );
    if (mounted && updated != null) setState(() => _card = updated);
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this card?'),
        content: Text('Remove ${_card.name} and its photo from this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _working = true);
    try {
      await widget.store.delete(_card);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      _notice('Could not delete this card. Please try again.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _showPhoto() {
    final photo = File(_card.photoPath);
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('Original photo'),
          ),
          body: SafeArea(
            child: InteractiveViewer(
              maxScale: 6,
              child: SizedBox.expand(child: _CardPhoto(photo: photo)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final code = _card.code;
    final format = _card.format;
    return PopScope(
      canPop: !_working,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Card'),
          actions: [
            IconButton(
              onPressed: _working ? null : _edit,
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit card',
            ),
            IconButton(
              onPressed: _working ? null : _delete,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete card',
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Text(
                _card.name,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              if (code != null && format != null)
                _CheckoutCode(code: code, format: format),
              const SizedBox(height: 12),
              Builder(
                builder: (buttonContext) => FilledButton.icon(
                  onPressed: _working ? null : () => _share(buttonContext),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share card'),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _showPhoto,
                icon: const Icon(Icons.photo_outlined),
                label: const Text('View original photo'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckoutCode extends StatelessWidget {
  const _CheckoutCode({required this.code, required this.format});

  final String code;
  final CardCodeFormat format;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(format.label, style: const TextStyle(color: Colors.black87)),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = math.min(
                constraints.maxWidth,
                format.square ? 344.0 : 640.0,
              );
              final quietZone = width * (format.square ? .14 : .105);
              return Semantics(
                image: true,
                label: 'Scannable ${format.label}',
                child: display.BarcodeWidget(
                  barcode: format.renderer(code),
                  data: code,
                  width: width,
                  height: format.square ? width : 112,
                  padding: EdgeInsets.symmetric(
                    horizontal: quietZone,
                    vertical: format.square ? quietZone : 0,
                  ),
                  drawText: false,
                  errorBuilder: (_, _) => const Center(
                    child: Text('Open the original photo to scan this code.'),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 14),
          SelectableText(
            code,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _CardPhoto extends StatelessWidget {
  const _CardPhoto({required this.photo, this.height});

  final File photo;
  final double? height;

  @override
  Widget build(BuildContext context) => Image.file(
    photo,
    height: height,
    fit: BoxFit.contain,
    cacheWidth: height == null ? null : 700,
    semanticLabel: 'Original loyalty card photo',
    errorBuilder: (_, _, _) => const Center(
      child: Text(
        'Could not display this photo.',
        style: TextStyle(color: Colors.grey),
      ),
    ),
  );
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  bool _found = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan barcode')),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Center one barcode in the frame.'),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final frame = Rect.fromCenter(
                    center: constraints.biggest.center(Offset.zero),
                    width: constraints.maxWidth * .84,
                    height: math.min(constraints.maxHeight * .70, 260),
                  );
                  return MobileScanner(
                    scanWindow: frame,
                    tapToFocus: true,
                    onDetect: (capture) {
                      if (_found || !mounted) return;
                      final codes = _readCodes(capture);
                      if (codes.length != 1) return;
                      _found = true;
                      Navigator.of(context).pop(codes.single);
                    },
                    overlayBuilder: (_, _) => IgnorePointer(
                      child: Stack(
                        children: [
                          Positioned.fromRect(
                            rect: frame,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    errorBuilder: (_, error) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          error.errorCode ==
                                  MobileScannerErrorCode.permissionDenied
                              ? 'Allow camera access in Settings, or go back to enter the barcode.'
                              : 'Camera unavailable. Go back to enter the barcode.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
