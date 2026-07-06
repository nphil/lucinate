import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/models/tailscale.dart';
import 'package:luci_mobile/state/tailscale_controller.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';

class TailscaleScreen extends ConsumerStatefulWidget {
  const TailscaleScreen({super.key});

  @override
  ConsumerState<TailscaleScreen> createState() => _TailscaleScreenState();
}

class _TailscaleScreenState extends ConsumerState<TailscaleScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(tailscaleControllerProvider).load();
    });
  }

  Future<void> _runAction(Future<bool> action) async {
    final ok = await action;
    if (!mounted) return;
    if (!ok) {
      final err = ref.read(tailscaleControllerProvider).error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err ?? 'Action failed'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(tailscaleControllerProvider);

    return Scaffold(
      appBar: LuciAppBar(
        title: 'Tailscale',
        showBack: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: controller.isLoading ? null : () => controller.load(),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(context, controller)),
    );
  }

  Widget _buildBody(BuildContext context, TailscaleController c) {
    if (!c.loaded && c.isLoading) {
      return const LuciLoadingWidget();
    }
    if (!c.loaded && c.error != null) {
      return LuciErrorDisplay(
        title: 'Couldn\'t reach Tailscale',
        message: c.error!,
        actionLabel: 'Retry',
        onAction: () => c.load(),
      );
    }
    if (!c.status.isInstalled && c.loaded) {
      return const LuciEmptyState(
        title: 'Tailscale not available',
        message: 'The tailscale package doesn\'t appear to be installed on '
            'this router.',
        icon: Icons.vpn_lock,
      );
    }

    return RefreshIndicator(
      onRefresh: () => c.load(),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: LuciSpacing.md),
        children: [
          _statusCard(context, c),
          const LuciSectionHeader('Routing'),
          _exitNodeTile(context, c),
          _toggleTile(
            context,
            title: 'Accept Routes',
            subtitle: 'Reach subnets advertised by other nodes (e.g. home LAN)',
            value: c.settings.acceptRoutes,
            busy: c.isBusy,
            onChanged: (v) => _runAction(c.setFlag('accept_routes', v)),
          ),
          _toggleTile(
            context,
            title: 'Advertise Exit Node',
            subtitle: 'Offer this router as an exit node to your tailnet',
            value: c.settings.advertiseExitNode,
            busy: c.isBusy,
            onChanged: (v) => _runAction(c.setFlag('advertise_exit_node', v)),
          ),
          const LuciSectionHeader('DNS & Security'),
          _toggleTile(
            context,
            title: 'MagicDNS (Accept DNS)',
            subtitle: 'Use Tailscale DNS. Warning: breaks package updates on '
                'this router',
            value: c.settings.acceptDns,
            busy: c.isBusy,
            onChanged: (v) => _onMagicDns(context, c, v),
          ),
          _toggleTile(
            context,
            title: 'Shields Up',
            subtitle: 'Block all inbound tailnet connections to this router',
            value: c.settings.shieldsUp,
            busy: c.isBusy,
            onChanged: (v) => _onShieldsUp(context, c, v),
          ),
          if (c.status.peers.isNotEmpty) ...[
            const LuciSectionHeader('Peers'),
            _peersCard(context, c),
          ],
          const SizedBox(height: LuciSpacing.xl),
        ],
      ),
    );
  }

  Widget _statusCard(BuildContext context, TailscaleController c) {
    final theme = Theme.of(context);
    final s = c.status;
    final (label, color) = switch (s.state) {
      'running' => ('Connected', Colors.green),
      'logout' => ('Needs Login', Colors.orange),
      _ => ('Disconnected', theme.colorScheme.error),
    };
    final exit = s.currentExitNode;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: LuciSpacing.md),
      decoration: LuciCardStyles.standardCard(context, isElevated: true),
      padding: const EdgeInsets.all(LuciSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: LuciSpacing.sm),
              Text(label, style: LuciTextStyles.cardTitle(context)),
              const Spacer(),
              if (c.isBusy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: LuciSpacing.md),
          _kv(context, 'Tailnet IP', s.ipv4.isEmpty ? '—' : s.ipv4),
          if (s.domainName.isNotEmpty) _kv(context, 'Tailnet', s.domainName),
          _kv(context, 'Peers online',
              '${s.onlinePeerCount} of ${s.peers.length}'),
          _kv(context, 'Exit node', exit?.hostname ?? 'None'),
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
          Expanded(
            child: Text(v, style: LuciTextStyles.detailValue(context)),
          ),
        ],
      ),
    );
  }

  Widget _exitNodeTile(BuildContext context, TailscaleController c) {
    final exit = c.status.currentExitNode;
    return _card(
      context,
      child: ListTile(
        leading: Icon(Icons.exit_to_app_rounded,
            color: Theme.of(context).colorScheme.primary),
        title: Text('Exit Node', style: LuciTextStyles.cardTitle(context)),
        subtitle: Text(
          exit == null ? 'None selected' : '${exit.hostname} (${exit.ip})',
          style: LuciTextStyles.cardSubtitle(context),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: c.isBusy ? null : () => _showExitNodePicker(context, c),
      ),
    );
  }

  Widget _toggleTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    required bool busy,
    required ValueChanged<bool> onChanged,
  }) {
    return _card(
      context,
      child: SwitchListTile.adaptive(
        title: Text(title, style: LuciTextStyles.cardTitle(context)),
        subtitle: Text(subtitle, style: LuciTextStyles.cardSubtitle(context)),
        value: value,
        onChanged: busy ? null : onChanged,
      ),
    );
  }

  Widget _peersCard(BuildContext context, TailscaleController c) {
    return _card(
      context,
      padding: EdgeInsets.zero,
      child: Column(
        children: ListTile.divideTiles(
          context: context,
          tiles: c.status.peers.map(
            (p) => ListTile(
              dense: true,
              leading: LuciStatusIndicators.statusDot(context, p.online),
              title: Text(p.hostname, style: LuciTextStyles.detailValue(context)),
              subtitle: Text(p.ip, style: LuciTextStyles.cardSubtitle(context)),
              trailing: p.isExitNode
                  ? const _Badge('Exit node', Colors.blue)
                  : (p.offersExitNode
                      ? _Badge('Offers exit', Colors.blueGrey)
                      : null),
            ),
          ),
        ).toList(),
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

  Future<void> _showExitNodePicker(
      BuildContext context, TailscaleController c) async {
    final candidates = c.status.exitNodeCandidates;
    final current = c.status.currentExitNode;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(LuciSpacing.md),
                child: Text('Select Exit Node',
                    style: LuciTextStyles.cardTitle(sheetContext)),
              ),
              ListTile(
                leading: const Icon(Icons.block_rounded),
                title: const Text('None'),
                trailing: current == null
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _runAction(c.setExitNode(null));
                },
              ),
              if (candidates.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(LuciSpacing.lg),
                  child: Text('No peers are offering an exit node.'),
                ),
              ...candidates.map(
                (p) => ListTile(
                  leading: LuciStatusIndicators.statusDot(sheetContext, p.online),
                  title: Text(p.hostname),
                  subtitle: Text(p.ip),
                  trailing: current?.id == p.id
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: p.online
                      ? () {
                          Navigator.of(sheetContext).pop();
                          _runAction(c.setExitNode(p.ip));
                        }
                      : null,
                ),
              ),
              const SizedBox(height: LuciSpacing.md),
            ],
          ),
        );
      },
    );
  }

  Future<void> _onMagicDns(
      BuildContext context, TailscaleController c, bool enable) async {
    // Enabling Accept DNS == disable_magic_dns -> '0'. Only the ON direction is
    // dangerous (it breaks apk/package updates on this router).
    if (enable) {
      final ok = await _confirmDanger(
        context,
        title: 'Enable MagicDNS?',
        message:
            'Enabling Accept DNS points this router\'s DNS at Tailscale '
            '(100.100.100.100). On this router there is no route to it, so '
            'package updates (apk / LuCI) will fail with "Operation not '
            'permitted".\n\nOnly enable if you know what you\'re doing.',
        confirmLabel: 'Enable anyway',
      );
      if (ok != true) return;
    }
    await _runAction(c.setFlag('disable_magic_dns', !enable));
  }

  Future<void> _onShieldsUp(
      BuildContext context, TailscaleController c, bool enable) async {
    if (enable) {
      final ok = await _confirmDanger(
        context,
        title: 'Enable Shields Up?',
        message:
            'Shields Up blocks ALL inbound tailnet connections to this router '
            '— including SSH and this app over Tailscale. If you\'re connected '
            'via Tailscale right now, you may lose access until you re-enable '
            'it from the router\'s own Wi-Fi (192.168.10.1).',
        confirmLabel: 'Enable anyway',
      );
      if (ok != true) return;
    }
    await _runAction(c.setFlag('shields_up', enable));
  }

  Future<bool?> _confirmDanger(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: colorScheme.error),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
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
