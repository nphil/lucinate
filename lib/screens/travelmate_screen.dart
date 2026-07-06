import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/models/travelmate.dart';
import 'package:luci_mobile/state/travelmate_controller.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:url_launcher/url_launcher_string.dart';

class TravelmateScreen extends ConsumerStatefulWidget {
  const TravelmateScreen({super.key});

  @override
  ConsumerState<TravelmateScreen> createState() => _TravelmateScreenState();
}

class _TravelmateScreenState extends ConsumerState<TravelmateScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(travelmateControllerProvider).load();
    });
  }

  Future<void> _runAction(Future<bool> action, {String? success}) async {
    final ok = await action;
    if (!mounted) return;
    final c = ref.read(travelmateControllerProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? (success ?? 'Done') : (c.error ?? 'Action failed')),
        backgroundColor:
            ok ? null : Theme.of(context).colorScheme.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(travelmateControllerProvider);
    return Scaffold(
      appBar: LuciAppBar(
        title: 'Travelmate',
        showBack: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: c.isLoading ? null : () => c.load(),
          ),
        ],
      ),
      floatingActionButton: c.loaded
          ? FloatingActionButton.extended(
              onPressed: c.isBusy ? null : () => _showAddFlow(context, c),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add network'),
            )
          : null,
      body: SafeArea(child: _buildBody(context, c)),
    );
  }

  Widget _buildBody(BuildContext context, TravelmateController c) {
    if (!c.loaded && c.isLoading) return const LuciLoadingWidget();
    if (!c.loaded && c.error != null) {
      return LuciErrorDisplay(
        title: 'Couldn\'t reach Travelmate',
        message: c.error!,
        actionLabel: 'Retry',
        onAction: () => c.load(),
      );
    }

    final s = c.status;
    return RefreshIndicator(
      onRefresh: () => c.load(),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: LuciSpacing.md),
        children: [
          _card(
            context,
            child: SwitchListTile.adaptive(
              title: Text('Travelmate', style: LuciTextStyles.cardTitle(context)),
              subtitle: Text(
                'Repeat nearby Wi-Fi as this router\'s uplink',
                style: LuciTextStyles.cardSubtitle(context),
              ),
              value: s.enabled,
              onChanged: c.isBusy
                  ? null
                  : (v) => _runAction(
                        c.setEnabled(v),
                        success: v ? 'Travelmate enabled' : 'Travelmate disabled',
                      ),
            ),
          ),
          if (s.captive) _captiveBanner(context),
          _statusCard(context, s),
          const LuciSectionHeader('Saved networks'),
          if (c.uplinks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(LuciSpacing.lg),
              child: Text(
                'No saved uplinks yet. Tap "Add network" to join one.',
                style: LuciTextStyles.cardSubtitle(context),
                textAlign: TextAlign.center,
              ),
            )
          else
            ...c.uplinks.map((u) => _uplinkTile(context, c, u)),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _captiveBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: LuciSpacing.md,
        vertical: LuciSpacing.xs,
      ),
      padding: const EdgeInsets.all(LuciSpacing.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: LuciCardStyles.standardRadius,
      ),
      child: Row(
        children: [
          Icon(Icons.language, color: scheme.onTertiaryContainer),
          const SizedBox(width: LuciSpacing.sm),
          Expanded(
            child: Text(
              'Captive portal detected — sign in via your browser.',
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
          TextButton(
            onPressed: () => launchUrlString(
              'http://neverssl.com',
              mode: LaunchMode.externalApplication,
            ),
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(BuildContext context, TravelmateStatus s) {
    final connected = s.isConnected;
    final color = connected ? Colors.green : Theme.of(context).colorScheme.error;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: LuciSpacing.md),
      decoration: LuciCardStyles.standardCard(context, isElevated: true),
      padding: const EdgeInsets.all(LuciSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                color: color,
                size: 20,
              ),
              const SizedBox(width: LuciSpacing.sm),
              Expanded(
                child: Text(
                  s.statusText.isEmpty
                      ? (s.enabled ? 'Not connected' : 'Disabled')
                      : s.statusText,
                  style: LuciTextStyles.cardTitle(context),
                ),
              ),
            ],
          ),
          if (s.activeSsid.isNotEmpty) ...[
            const SizedBox(height: LuciSpacing.sm),
            _kv(context, 'Connected to', s.activeSsid),
            if (s.subnet.isNotEmpty) _kv(context, 'Uplink subnet', s.subnet),
          ],
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(k, style: LuciTextStyles.detailLabel(context)),
          ),
          Expanded(child: Text(v, style: LuciTextStyles.detailValue(context))),
        ],
      ),
    );
  }

  Widget _uplinkTile(
      BuildContext context, TravelmateController c, TravelmateUplink u) {
    final active = c.status.activeSsid.isNotEmpty &&
        c.status.activeSsid == u.ssid;
    return _card(
      context,
      child: ListTile(
        leading: Icon(
          active ? Icons.wifi_rounded : Icons.wifi_outlined,
          color: active
              ? Colors.green
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        title: Text(u.ssid, style: LuciTextStyles.cardTitle(context)),
        subtitle: Text(
          '${u.device}${u.enabled ? '' : ' • disabled'}',
          style: LuciTextStyles.cardSubtitle(context),
        ),
        trailing: active
            ? const _Badge('Connected', Colors.green)
            : null,
      ),
    );
  }

  Widget _card(BuildContext context,
      {required Widget child, EdgeInsets? padding}) {
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: LuciSpacing.md,
        vertical: LuciSpacing.xs,
      ),
      decoration: LuciCardStyles.standardCard(context),
      clipBehavior: Clip.antiAlias,
      padding: padding,
      child: child,
    );
  }

  // ---- Add flow ----

  Future<void> _showAddFlow(BuildContext context, TravelmateController c) async {
    c.scan();
    final selected = await showModalBottomSheet<WifiScanResult>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (ctx, scrollController) {
            return Consumer(
              builder: (ctx, ref, _) {
                final ctrl = ref.watch(travelmateControllerProvider);
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(LuciSpacing.md),
                      child: Row(
                        children: [
                          Text('Nearby networks',
                              style: LuciTextStyles.cardTitle(ctx)),
                          const Spacer(),
                          if (ctrl.isScanning)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            IconButton(
                              icon: const Icon(Icons.refresh_rounded),
                              onPressed: () => ctrl.scan(),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: (ctrl.scanResults.isEmpty && !ctrl.isScanning)
                          ? Center(
                              child: Text(
                                'No networks found. Tap refresh to scan again.',
                                style: LuciTextStyles.cardSubtitle(ctx),
                              ),
                            )
                          : ListView(
                              controller: scrollController,
                              children: ctrl.scanResults
                                  .map((r) => ListTile(
                                        leading: Icon(
                                          r.encrypted
                                              ? Icons.lock_rounded
                                              : Icons.wifi_rounded,
                                        ),
                                        title: Text(r.ssid),
                                        subtitle: Text(
                                          '${r.band}GHz • ${r.qualityPercent}%'
                                          '${r.encrypted ? '' : ' • open'}',
                                        ),
                                        trailing: Text('${r.signal} dBm'),
                                        onTap: () =>
                                            Navigator.of(ctx).pop(r),
                                      ))
                                  .toList(),
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );

    if (selected == null || !mounted) return;

    String password = '';
    if (selected.encrypted) {
      final pw = await _askPassword(context, selected.ssid);
      if (pw == null) return;
      password = pw;
    }

    await _runAction(
      c.addUplink(
        ssid: selected.ssid,
        password: password,
        device: selected.device,
        encryption: selected.encryption,
      ),
      success: 'Added ${selected.ssid} — connecting…',
    );
  }

  Future<String?> _askPassword(BuildContext context, String ssid) {
    final controller = TextEditingController();
    var obscure = true;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: Text('Password for "$ssid"'),
            content: TextField(
              controller: controller,
              autofocus: true,
              obscureText: obscure,
              decoration: InputDecoration(
                labelText: 'Wi-Fi password',
                suffixIcon: IconButton(
                  icon: Icon(
                    obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => obscure = !obscure),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controller.text),
                child: const Text('Connect'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
