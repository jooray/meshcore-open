import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';
import '../services/companion_device_service.dart';
import '../storage/last_radio_store.dart';

/// Connect on start, and on Android "Keep connected in the background".
class RadioConnectionSettingsSection extends StatelessWidget {
  const RadioConnectionSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settingsService = context.watch<AppSettingsService>();
    final l10n = context.l10n;
    return Column(
      children: [
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          secondary: const Icon(Icons.power_settings_new, size: 24),
          title: Text(l10n.appSettings_autoConnectOnStart),
          subtitle: Text(l10n.appSettings_autoConnectOnStartSubtitle),
          value: settingsService.settings.autoConnectOnStart,
          onChanged: settingsService.setAutoConnectOnStart,
        ),
        const KeepConnectedTile(divider: true),
      ],
    );
  }
}

/// Switch that associates the last Bluetooth radio with Android's Companion
/// Device Manager. Hidden where that does not exist.
class KeepConnectedTile extends StatefulWidget {
  /// Draws a divider above the tile when it is shown.
  final bool divider;

  /// Hides the tile once the radio is associated (for the connect sheet).
  final bool onlyWhenOff;

  const KeepConnectedTile({
    super.key,
    this.divider = false,
    this.onlyWhenOff = false,
  });

  @override
  State<KeepConnectedTile> createState() => _KeepConnectedTileState();
}

class _KeepConnectedTileState extends State<KeepConnectedTile> {
  final _companion = CompanionDeviceService.instance;
  bool _supported = false;
  bool _observesPresence = false;
  bool? _associated;
  String? _address;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final supported = await _companion.isSupported();
    if (!supported) return;
    final observes = await _companion.canObservePresence();
    final radio = _bleRadio();
    final associated = radio == null
        ? false
        : await _companion.isAssociated(radio.bleRemoteId!);
    if (!mounted) return;
    setState(() {
      _supported = true;
      _observesPresence = observes;
      _address = radio?.bleRemoteId;
      _associated = associated;
    });
  }

  LastRadio? _bleRadio() {
    final radio = context.read<MeshCoreConnector>().lastRadio;
    return radio != null && radio.canReconnectBle ? radio : null;
  }

  Future<void> _toggle(bool value, String name) async {
    final address = _address;
    if (address == null) return;
    setState(() => _busy = true);
    if (!value) {
      await _companion.disassociate(address);
    } else {
      final result = await _companion.associate(address, name: name);
      if (mounted) {
        final message = switch (result) {
          CompanionAssociationResult.associated => null,
          CompanionAssociationResult.cancelled => null,
          CompanionAssociationResult.notFound =>
            context.l10n.appSettings_keepConnectedNotFound(name),
          CompanionAssociationResult.failed =>
            context.l10n.appSettings_keepConnectedFailed,
        };
        if (message != null) {
          showDismissibleSnackBar(context, content: Text(message));
        }
      }
    }
    final associated = await _companion.isAssociated(address);
    if (!mounted) return;
    setState(() {
      _associated = associated;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when another radio becomes the last one.
    final radioId = context.select<MeshCoreConnector, String?>((c) {
      final radio = c.lastRadio;
      return radio != null && radio.canReconnectBle ? radio.bleRemoteId : null;
    });
    if (radioId != _address && _supported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
    final associated = _associated;
    if (!_supported || associated == null) return const SizedBox.shrink();
    if (widget.onlyWhenOff && (associated || _address == null)) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final connector = context.read<MeshCoreConnector>();
    final name = connector.lastRadioName ?? '';
    final hasRadio = _address != null;
    final subtitle = !hasRadio
        ? l10n.appSettings_keepConnectedNoRadio
        : _observesPresence
        ? l10n.appSettings_keepConnectedSubtitle(name)
        : l10n.appSettings_keepConnectedSubtitleNoPresence(name);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.divider) const Divider(height: 1, indent: 16),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          secondary: const Icon(Icons.bluetooth_connected, size: 24),
          title: Text(l10n.appSettings_keepConnected),
          subtitle: Text(subtitle),
          value: associated,
          onChanged: hasRadio && !_busy
              ? (value) => _toggle(value, name)
              : null,
        ),
      ],
    );
  }
}
