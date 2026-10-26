import 'dart:async';

import 'package:flutter/material.dart';

import 'local_api_pairing.dart';
import 'local_api_service.dart';

/// Shows the consent dialog when an app asks to use the radio.
///
/// Wraps the app so the dialog can appear over any screen. Nothing is granted
/// silently: an unanswered request times out and is denied.
class LocalApiPairingHost extends StatefulWidget {
  final Widget child;

  const LocalApiPairingHost({super.key, required this.child});

  @override
  State<LocalApiPairingHost> createState() => _LocalApiPairingHostState();
}

class _LocalApiPairingHostState extends State<LocalApiPairingHost> {
  StreamSubscription<PairingRequest>? _subscription;
  final List<PairingRequest> _queue = [];
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    final service = LocalApiService.instance;
    if (service != null) {
      _subscription = service.pairingBroker.requests.listen(_enqueue);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _enqueue(PairingRequest request) {
    _queue.add(request);
    unawaited(_showNext());
  }

  Future<void> _showNext() async {
    if (_showing || !mounted || _queue.isEmpty) return;
    _showing = true;
    final request = _queue.removeAt(0);
    final allowed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Allow connection?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '“${request.name}” wants to send and receive MeshCore messages '
              'through this app while it keeps the radio connected.',
            ),
            const SizedBox(height: 16),
            Text(
              'Key fingerprint',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            SelectableText(
              request.fingerprint,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Only allow an app you trust: it will be able to read your '
              'messages and transmit on your radio.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    LocalApiService.instance?.pairingBroker.resolve(
      request.id,
      allowed ?? false,
    );
    _showing = false;
    if (_queue.isNotEmpty) unawaited(_showNext());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
