import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:nsd/nsd.dart' as nsd;

import 'card_store.dart';
import 'l10n/app_localizations.dart';
import 'nearby_transport.dart';

typedef _Peer = ({String name, InternetAddress address, int port});

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
  final _clients = <NearbyMergeClient>{};
  List<_Peer> _peers = [];
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
  bool _merging = false;

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
        _merging = false;
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
    if (!active && pairRoute != null) {
      scheduleMicrotask(() => _dismissPairRoute(pairRoute));
    }
    _networkChange = _networkChange.then((_) async {
      await _stopNetwork();
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
    final clients = _clients.toList();
    _discovery = null;
    _registration = null;
    _server = null;
    _clients.clear();
    discovery?.removeListener(_refreshPeers);
    await Future.wait([
      if (discovery != null) _close(() => nsd.stopDiscovery(discovery)),
      if (registration != null) _close(() => nsd.unregister(registration)),
      if (server != null) _close(server.close),
      for (final client in clients) _close(client.close),
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
    final peers = <String, _Peer>{};
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
    setState(() => _merging = true);
    final connected = <NearbyMergeClient>[];
    final sessions = <NearbyMergeClient>[];
    var received = 0;
    var sent = 0;
    var incomplete = false;
    try {
      final localKeys = _keys(await widget.store.mergeManifest());
      for (final peer in targets) {
        if (!_isCurrent(generation)) return;
        try {
          final client = await NearbyMergeClient.connect(
            address: peer.address,
            port: peer.port,
            name: _alias,
            confirm: (name, code) => _confirm(name, code, generation),
          );
          if (client == null) {
            incomplete = true;
            continue;
          }
          if (!_isCurrent(generation)) {
            await _close(client.close);
            return;
          }
          _clients.add(client);
          connected.add(client);
          final manifest = await client.manifest();
          sessions.add(client);
          for (final card in manifest) {
            if (!_isCurrent(generation)) return;
            if (card.keys.any(localKeys.contains)) continue;
            final data = await client.downloadCard(card.id);
            if (!_isCurrent(generation)) return;
            if (data == null) {
              incomplete = true;
            } else if (await widget.store.importForMerge(data)) {
              received++;
              localKeys.addAll(card.keys);
            }
          }
        } catch (_) {
          incomplete = true;
        }
      }

      if (!_isCurrent(generation)) return;
      final union = await widget.store.mergeManifest();
      for (final client in sessions) {
        if (!_isCurrent(generation)) return;
        try {
          final remoteKeys = _keys(await client.manifest());
          for (final card in union) {
            if (!_isCurrent(generation)) return;
            if (card.keys.any(remoteKeys.contains)) continue;
            final data = await widget.store.exportForMerge(card.id);
            if (!_isCurrent(generation)) return;
            if (data == null) {
              incomplete = true;
              continue;
            }
            if (await client.sendCard(data)) sent++;
            remoteKeys.addAll(card.keys);
          }
        } catch (_) {
          incomplete = true;
        }
      }
    } catch (_) {
      incomplete = true;
    } finally {
      _clients.removeAll(connected);
      await Future.wait(connected.map((client) => _close(client.close)));
      if (_isCurrent(generation)) setState(() => _merging = false);
    }

    if (!mounted || !_isCurrent(generation)) return;
    final l10n = AppLocalizations.of(context)!;
    final message = sessions.isEmpty
        ? l10n.nearbyMergeUnavailable
        : l10n.nearbyMergeComplete(sent, received) +
              (incomplete ? '\n${l10n.nearbyMergePartial}' : '');
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Set<String> _keys(List<MergeCardRef> manifest) => {
    for (final card in manifest) ...card.keys,
  };

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
