import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:nsd/nsd.dart' as nsd;

import 'card_store.dart';
import 'l10n/app_localizations.dart';
import 'nearby_merge.dart';
import 'nearby_transport.dart';

class NearbyMergePage extends StatefulWidget {
  const NearbyMergePage({super.key, required this.store});

  final CardStore store;

  @override
  State<NearbyMergePage> createState() => _NearbyMergePageState();
}

class _NearbyMergePageState extends State<NearbyMergePage>
    with WidgetsBindingObserver {
  static const _serviceType = '_loyaltypocket._tcp';

  late final _alias = _deviceAlias();
  final _selected = <String>{};
  List<NearbyMergePeer> _peers = [];
  NearbyMergeServer? _server;
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  Future<void> _networkChange = Future.value();
  int _generation = 0;
  int _incomingCount = 0;
  bool _active = true;
  bool _starting = true;
  bool _discoveryFailed = false;
  DialogRoute<bool>? _pairRoute;
  NearbyMerge? _mergeOperation;

  bool get _merging => _mergeOperation != null;

  static String _deviceAlias() {
    final id = Random.secure().nextInt(1 << 24).toRadixString(16);
    final platform = Platform.isIOS ? 'iPhone' : 'Android';
    return '$platform-${id.padLeft(6, '0').toUpperCase()}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleNetwork(true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isBackground =
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (isBackground && _active) {
      setState(() {
        _starting = true;
        _discoveryFailed = false;
        _peers = [];
        _selected.clear();
      });
      _scheduleNetwork(false);
    } else if (state == AppLifecycleState.resumed && !_active) {
      _scheduleNetwork(true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scheduleNetwork(false);
    super.dispose();
  }

  bool _isCurrent(int generation) =>
      mounted && _active && generation == _generation;

  void _scheduleNetwork(bool active) {
    _active = active;
    final generation = ++_generation;
    final pairRoute = _pairRoute;
    final cancellation = _mergeOperation?.cancel();
    _mergeOperation = null;
    if (!active && pairRoute != null) {
      scheduleMicrotask(() => _dismissPairRoute(pairRoute));
    }
    _networkChange = _networkChange.then((_) async {
      await Future.wait([_stopNetwork(), ?cancellation]);
      if (_isCurrent(generation)) await _startNetwork(generation);
    });
  }

  void _retry() {
    setState(() {
      _starting = true;
      _discoveryFailed = false;
    });
    _scheduleNetwork(true);
  }

  Future<void> _startNetwork(int generation) async {
    try {
      final server = await NearbyMergeServer.start(
        store: widget.store,
        name: _alias,
        confirm: (name, code) => _merging || !_isCurrent(generation)
            ? Future.value(false)
            : _confirm(name, code, generation),
        onImported: () {
          if (_isCurrent(generation)) setState(() => _incomingCount++);
        },
      );
      _server = server;
      if (!_isCurrent(generation)) return;
      _registration = await nsd.register(
        nsd.Service(name: _alias, type: _serviceType, port: server.port),
      );
      if (!_isCurrent(generation)) return;
      final discovery = await nsd.startDiscovery(
        _serviceType,
        ipLookupType: nsd.IpLookupType.any,
      );
      _discovery = discovery;
      if (!_isCurrent(generation)) return;
      discovery.addListener(_refreshPeers);
      _refreshPeers();
    } catch (_) {
      await _stopNetwork();
      if (_isCurrent(generation)) {
        setState(() {
          _starting = false;
          _discoveryFailed = true;
        });
      }
    }
  }

  Future<void> _stopNetwork() async {
    final discovery = _discovery;
    final registration = _registration;
    final server = _server;
    _discovery = null;
    _registration = null;
    _server = null;
    discovery?.removeListener(_refreshPeers);
    await Future.wait([
      if (discovery != null) _close(() => nsd.stopDiscovery(discovery)),
      if (registration != null) _close(() => nsd.unregister(registration)),
      if (server != null) _close(server.close),
    ]);
  }

  Future<void> _close(Future<void> Function() close) async {
    try {
      await close();
    } catch (_) {
      // A peer may already have closed its connection.
    }
  }

  void _refreshPeers() {
    final discovery = _discovery;
    if (!mounted || !_active || discovery == null) return;
    final peers = <String, NearbyMergePeer>{};
    for (final service in discovery.services) {
      final name = service.name;
      final port = service.port;
      if (name == null ||
          name.isEmpty ||
          name == _alias ||
          name == _registration?.service.name ||
          port == null ||
          port < 1 ||
          port > 65535) {
        continue;
      }
      final addresses = (service.addresses ?? []).where(
        (address) => !address.isLoopback && !address.isMulticast,
      );
      final address =
          addresses
              .where((ip) => ip.type == InternetAddressType.IPv4)
              .firstOrNull ??
          addresses.firstOrNull;
      if (address != null) {
        peers[name] = (name: name, address: address, port: port);
      }
    }
    setState(() {
      _starting = false;
      _peers = peers.values.toList()
        ..sort((first, second) => first.name.compareTo(second.name));
      _selected.retainAll(peers.keys);
    });
  }

  Future<bool> _confirm(String name, String code, int generation) async {
    if (!_isCurrent(generation) ||
        _pairRoute != null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return AlertDialog(
          scrollable: true,
          title: Text(l10n.nearbyMergePairTitle(name)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.nearbyMergePairInstructions),
              const SizedBox(height: 16),
              SelectableText(
                code,
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.nearbyMergePairConfirm),
            ),
          ],
        );
      },
    );
    _pairRoute = route;
    final expiry = Timer(
      const Duration(seconds: 110),
      () => _dismissPairRoute(route),
    );
    try {
      final confirmed = await navigator.push(route);
      return _isCurrent(generation) && confirmed == true;
    } finally {
      expiry.cancel();
      _pairRoute = null;
    }
  }

  void _dismissPairRoute(DialogRoute<bool> route) {
    if (route.isActive) route.navigator?.removeRoute(route, false);
  }

  Future<void> _merge() async {
    final generation = _generation;
    final targets = _peers
        .where((peer) => _selected.contains(peer.name))
        .toList();
    if (_merging || targets.isEmpty) return;
    final operation = NearbyMerge(widget.store);
    setState(() => _mergeOperation = operation);
    try {
      final result = await operation.run(
        peers: targets,
        name: _alias,
        confirm: (name, code) => _confirm(name, code, generation),
      );
      if (!mounted || !_isCurrent(generation) || result == null) return;
      final l10n = AppLocalizations.of(context)!;
      final message = result.connected
          ? l10n.nearbyMergeComplete(result.sent, result.received) +
                (result.incomplete ? '\n${l10n.nearbyMergePartial}' : '')
          : l10n.nearbyMergeUnavailable;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted && _mergeOperation == operation) {
        setState(() => _mergeOperation = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.nearbyMergeTitle)),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l10n.nearbyMergeInstructions),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.smartphone),
                title: Text(l10n.nearbyMergeOwnDevice(_alias)),
                subtitle: _incomingCount == 0
                    ? null
                    : Text(l10n.nearbyMergeIncoming(_incomingCount)),
              ),
            ),
            const SizedBox(height: 12),
            if (_starting || _merging) const LinearProgressIndicator(),
            if (_starting) ...[
              const SizedBox(height: 8),
              Text(l10n.nearbyMergeSearching),
            ] else if (_discoveryFailed) ...[
              Text(l10n.nearbyMergeDiscoveryError),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _retry,
                child: Text(l10n.nearbyMergeRetry),
              ),
            ] else if (_peers.isEmpty)
              Text(l10n.nearbyMergeNoPeers)
            else
              for (final peer in _peers)
                CheckboxListTile(
                  key: ValueKey(peer.name),
                  title: Text(peer.name),
                  secondary: const Icon(Icons.smartphone),
                  value: _selected.contains(peer.name),
                  onChanged: _merging
                      ? null
                      : (selected) => setState(() {
                          if (selected == true) {
                            _selected.add(peer.name);
                          } else {
                            _selected.remove(peer.name);
                          }
                        }),
                ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: _starting || _merging || _selected.isEmpty ? null : _merge,
          icon: const Icon(Icons.sync),
          label: Text(
            _merging ? l10n.nearbyMergeWorking : l10n.nearbyMergeStart,
          ),
        ),
      ),
    );
  }
}
