import 'dart:io';

import 'package:barcode_widget/barcode_widget.dart' as display;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'bluetooth_sync.dart';
import 'card_store.dart';
import 'l10n/app_localizations.dart';
import 'nearby_merge_page.dart';

class BluetoothSyncPage extends StatefulWidget {
  const BluetoothSyncPage({super.key, required this.sync, required this.store});

  final BluetoothSync sync;
  final CardStore store;

  @override
  State<BluetoothSyncPage> createState() => _BluetoothSyncPageState();
}

class _BluetoothSyncPageState extends State<BluetoothSyncPage> {
  bool _busy = false;

  BluetoothSync get _sync => widget.sync;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.bluetoothSyncError)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showInvitation() async {
    final code = await _sync.createInvitation();
    if (code == null || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AnimatedBuilder(
          animation: _sync,
          builder: (context, _) => AlertDialog(
            title: Text(l10n.bluetoothSyncInvite),
            content: _sync.invitation != code
                ? Text(l10n.bluetoothSyncInviteClosed)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l10n.bluetoothSyncInviteHelp),
                      const SizedBox(height: 16),
                      display.BarcodeWidget(
                        barcode: display.Barcode.qrCode(),
                        data: code,
                        width: 200,
                        height: 200,
                        padding: const EdgeInsets.all(12),
                        backgroundColor: Colors.white,
                        color: Colors.black,
                        drawText: false,
                      ),
                    ],
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(MaterialLocalizations.of(context).closeButtonLabel),
              ),
            ],
          ),
        ),
      );
    } finally {
      _sync.closeInvitation(code);
    }
  }

  Future<void> _scanInvitation() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _BluetoothInviteScanner()),
    );
    if (code != null && mounted) await _sync.joinInvitation(code);
  }

  Future<void> _rename() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _DeviceNameDialog(name: _sync.deviceName),
    );
    if (name != null && mounted) await _sync.rename(name);
  }

  Future<void> _leave() async {
    final l10n = AppLocalizations.of(context)!;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.bluetoothSyncLeave),
        content: Text(l10n.bluetoothSyncLeaveHelp),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.bluetoothSyncLeave),
          ),
        ],
      ),
    );
    if (leave == true && mounted) await _sync.leave();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.bluetoothSyncTitle)),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _sync,
          builder: (context, _) => _sync.initializing
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(l10n.bluetoothSyncIntro),
                    const SizedBox(height: 12),
                    if (_sync.supported) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.smartphone),
                        title: Text(l10n.bluetoothSyncDeviceName),
                        subtitle: Text(_sync.deviceName),
                        trailing: const Icon(Icons.edit_outlined),
                        onTap: _busy ? null : () => _run(_rename),
                      ),
                      if (_sync.hasGroup)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.bluetoothSyncAutomatic),
                          subtitle: Text(
                            Platform.isIOS
                                ? l10n.bluetoothSyncIosHint
                                : l10n.bluetoothSyncAndroidHint,
                          ),
                          value: _sync.enabled,
                          onChanged: _busy
                              ? null
                              : (value) => _run(() => _sync.setEnabled(value)),
                        ),
                      _statusTile(l10n),
                      if (_sync.joining)
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _run(_sync.cancelJoin),
                          child: Text(
                            MaterialLocalizations.of(context).cancelButtonLabel,
                          ),
                        )
                      else ...[
                        FilledButton.icon(
                          icon: const Icon(Icons.qr_code),
                          label: Text(l10n.bluetoothSyncInvite),
                          onPressed: _busy ? null : () => _run(_showInvitation),
                        ),
                        if (!_sync.hasGroup)
                          OutlinedButton.icon(
                            icon: const Icon(Icons.qr_code_scanner),
                            label: Text(l10n.bluetoothSyncJoin),
                            onPressed: _busy
                                ? null
                                : () => _run(_scanInvitation),
                          ),
                      ],
                      if (_sync.hasGroup) ...[
                        const Divider(),
                        _section(context, l10n.bluetoothSyncDevices),
                        if (_sync.devices.isEmpty)
                          Text(l10n.bluetoothSyncNoDevices),
                        for (final device in _sync.devices)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.devices_other),
                            title: Text(device),
                          ),
                        const Divider(),
                        _section(context, l10n.bluetoothSyncHistory),
                        if (_sync.history.isEmpty)
                          Text(l10n.bluetoothSyncNoHistory),
                        for (final entry in _sync.history) _historyTile(entry),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            onPressed: _busy ? null : () => _run(_leave),
                            child: Text(l10n.bluetoothSyncLeave),
                          ),
                        ),
                      ],
                    ],
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.wifi),
                      title: Text(l10n.bluetoothSyncWifi),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : () => Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) =>
                                    NearbyMergePage(store: widget.store),
                              ),
                            ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _statusTile(AppLocalizations l10n) {
    final status = _sync.status;
    final label = switch (status) {
      BluetoothSyncStatus.disabled => null,
      BluetoothSyncStatus.starting => l10n.bluetoothSyncStarting,
      BluetoothSyncStatus.ready when _sync.joining => l10n.bluetoothSyncJoining,
      BluetoothSyncStatus.ready when _sync.syncing => l10n.bluetoothSyncWorking,
      BluetoothSyncStatus.ready => l10n.bluetoothSyncReady,
      BluetoothSyncStatus.permissionDenied => l10n.bluetoothSyncPermission,
      BluetoothSyncStatus.bluetoothOff => l10n.bluetoothSyncRadioOff,
      BluetoothSyncStatus.unavailable => l10n.bluetoothSyncUnavailable,
    };
    if (label == null) return const SizedBox.shrink();
    final canRetry =
        _sync.enabled &&
        status != BluetoothSyncStatus.ready &&
        status != BluetoothSyncStatus.starting;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.bluetooth),
      title: Text(label),
      trailing: canRetry
          ? TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => _sync.setEnabled(true)),
              child: Text(l10n.retry),
            )
          : null,
    );
  }

  Widget _historyTile(BluetoothSyncEntry entry) {
    final l10n = AppLocalizations.of(context)!;
    final format = MaterialLocalizations.of(context);
    final time = entry.time.toLocal();
    final label = [
      format.formatShortDate(time),
      format.formatTimeOfDay(
        TimeOfDay.fromDateTime(time),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      ),
    ].join(' · ');
    final counts = entry.sent > 0 || entry.received > 0;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(entry.incomplete ? Icons.sync_problem : Icons.sync),
      title: Text(entry.device),
      subtitle: Text(
        [
          label,
          if (counts) l10n.nearbyMergeComplete(entry.sent, entry.received),
          if (entry.incomplete)
            l10n.bluetoothSyncInterrupted
          else if (!counts)
            l10n.bluetoothSyncUpToDate,
        ].join('\n'),
      ),
    );
  }

  Widget _section(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(label, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({required this.name});

  final String name;

  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final _name = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.bluetoothSyncDeviceName),
      content: TextField(
        controller: _name,
        maxLength: 32,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => Navigator.of(context).pop(_name.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}

class _BluetoothInviteScanner extends StatefulWidget {
  const _BluetoothInviteScanner();

  @override
  State<_BluetoothInviteScanner> createState() =>
      _BluetoothInviteScannerState();
}

class _BluetoothInviteScannerState extends State<_BluetoothInviteScanner> {
  final _controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.bluetoothSyncJoin)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.bluetoothSyncScanHint),
            ),
            Expanded(
              child: MobileScanner(
                controller: _controller,
                onDetect: (capture) {
                  if (_done || !mounted) return;
                  for (final barcode in capture.barcodes) {
                    final value = barcode.rawValue;
                    if (value != null && BluetoothSync.isInvitation(value)) {
                      _done = true;
                      Navigator.of(context).pop(value);
                      return;
                    }
                  }
                },
                errorBuilder: (_, error) => Center(
                  child: Text(
                    error.errorCode == MobileScannerErrorCode.permissionDenied
                        ? l10n.scanCameraPermissionDenied
                        : l10n.scanCameraUnavailable,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
