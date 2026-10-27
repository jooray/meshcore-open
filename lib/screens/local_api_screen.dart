import 'package:flutter/material.dart';

import '../services/local_api/local_api_pairing.dart';
import '../services/local_api/local_api_server.dart';
import '../services/local_api/local_api_service.dart';

/// Settings for the loopback API other apps use to share this radio.
///
/// Strings are English-only for now; the screen is new and will be localized
/// with the rest of the app once the transport is settled upstream.
class LocalApiScreen extends StatefulWidget {
  const LocalApiScreen({super.key});

  @override
  State<LocalApiScreen> createState() => _LocalApiScreenState();
}

class _LocalApiScreenState extends State<LocalApiScreen> {
  LocalApiService? get _service => LocalApiService.instance;
  List<PairedClient> _clients = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final service = _service;
    if (service == null) return;
    await service.pairingStore.load();
    if (!mounted) return;
    setState(() => _clients = service.pairedClients);
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    return Scaffold(
      appBar: AppBar(title: const Text('Local API')),
      body: service == null
          ? const Center(child: Text('The API is not available.'))
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                SwitchListTile(
                  title: const Text('Local API'),
                  subtitle: const Text(
                    'Let other apps on this phone use the radio through MeshCore Open. '
                    'They ask for permission the first time.',
                  ),
                  value: service.isEnabled,
                  onChanged: _busy
                      ? null
                      : (value) async {
                          setState(() => _busy = true);
                          await service.setEnabled(value);
                          if (mounted) setState(() => _busy = false);
                        },
                ),
                ListTile(
                  title: const Text('Address'),
                  subtitle: Text(
                    service.isEnabled
                        ? 'ws://127.0.0.1:${service.port ?? LocalApiServer.defaultPort}/api/v1'
                        : 'Off',
                  ),
                ),
                const Divider(),
                const ListTile(
                  title: Text('Allowed apps'),
                  subtitle: Text(
                    'Approved when they first connected. Removing one makes it ask again.',
                  ),
                ),
                if (_clients.isEmpty)
                  const ListTile(
                    title: Text('No apps yet'),
                    subtitle: Text(
                      'A request appears here after an app connects.',
                    ),
                  ),
                for (final client in _clients)
                  ListTile(
                    leading: const Icon(Icons.apps),
                    title: Text(client.name),
                    subtitle: Text(
                      '${client.fingerprint}\nPaired ${client.pairedAt.toLocal()}',
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await service.revoke(client.publicKey);
                        await _reload();
                      },
                    ),
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('Clear stored radio data'),
                  subtitle: const Text(
                    'Removes channel data kept for apps that were not running.',
                  ),
                  onTap: () async {
                    await service.archive.clear();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Stored radio data cleared'),
                      ),
                    );
                  },
                ),
              ],
            ),
    );
  }
}
