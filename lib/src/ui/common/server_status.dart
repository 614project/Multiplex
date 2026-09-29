import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/url_tools.dart';
import '../../models/api_platform.dart';
import '../../state/app_state.dart';
import '../../state/project_session.dart';
import '../theme.dart';

Color serverStatusColor(BuildContext context, ServerStatus status) => switch (status) {
  ServerStatus.online => const Color(0xFF2E9E5B),
  ServerStatus.offline => context.colors.error,
  ServerStatus.checking => context.colors.tertiary,
  ServerStatus.unknown => context.colors.outline,
};

String serverStatusLabel(ServerStatus status) => switch (status) {
  ServerStatus.online => 'Connected',
  ServerStatus.offline => 'Offline',
  ServerStatus.checking => 'Checking…',
  ServerStatus.unknown => 'Not checked',
};

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.status, this.size = 10});

  final ServerStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = serverStatusColor(context, status);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 6)],
      ),
    );
  }
}

/// Shows where the project sends requests and whether that server answers. Opens [showConnectionSheet].
class ServerStatusChip extends StatelessWidget {
  const ServerStatusChip({super.key, required this.session, this.compact = false});

  final ProjectSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final host = EndpointResolver.describe(session.resolvedApiBaseUrl);
        return Tooltip(
          message: session.serverMessage.isEmpty ? serverStatusLabel(session.serverStatus) : session.serverMessage,
          child: ActionChip(
            avatar: StatusDot(status: session.serverStatus),
            label: Text(compact ? session.settings.platform.label : '${session.settings.platform.label} · $host'),
            onPressed: () => showConnectionSheet(context, session),
          ),
        );
      },
    );
  }
}

Future<void> showConnectionSheet(BuildContext context, ProjectSession session) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConnectionPanel(session: session),
    ),
  );
}

/// Server settings of a project plus the app-wide fallback URL, with a live status line.
class ConnectionPanel extends StatefulWidget {
  const ConnectionPanel({super.key, required this.session});

  final ProjectSession session;

  @override
  State<ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends State<ConnectionPanel> {
  late final TextEditingController _projectUrl = TextEditingController(text: widget.session.settings.apiBaseUrl);
  late final TextEditingController _globalUrl = TextEditingController(
    text: context.read<AppState>().preferences.globalApiBaseUrl,
  );

  @override
  void dispose() {
    _projectUrl.dispose();
    _globalUrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final session = widget.session;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final colors = context.colors;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Server connection', style: context.text.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Multiplex sends txt2img requests to Stable Diffusion WebUI (A1111/Forge, launched with --api) '
                'or ComfyUI. To use a PC from your phone, launch the server with --listen and enter its LAN address.',
                style: context.text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Card(
                color: colors.surfaceContainerHigh,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      StatusDot(status: session.serverStatus, size: 14),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(serverStatusLabel(session.serverStatus), style: context.text.titleSmall),
                            Text(
                              session.serverMessage.isEmpty
                                  ? EndpointDescription.of(session.resolvedApiBaseUrl)
                                  : session.serverMessage,
                              style: context.text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Check again',
                        onPressed: session.serverStatus == ServerStatus.checking ? null : session.refreshServer,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SegmentedButton<ApiPlatform>(
                segments: const [
                  ButtonSegment(value: ApiPlatform.webUi, label: Text('WebUI'), icon: Icon(Icons.web)),
                  ButtonSegment(
                    value: ApiPlatform.comfyUi,
                    label: Text('ComfyUI'),
                    icon: Icon(Icons.account_tree_outlined),
                  ),
                ],
                selected: {session.settings.platform},
                onSelectionChanged: (selection) => session.setPlatform(selection.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _projectUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Project API base URL',
                  hintText: session.apiBaseUrlPlaceholder,
                  helperText: session.apiBaseUrlDescription,
                  helperMaxLines: 3,
                  prefixIcon: const Icon(Icons.link),
                ),
                onChanged: session.setApiBaseUrl,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _globalUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Global API base URL',
                  hintText: 'Used by every project whose own URL is empty',
                  prefixIcon: Icon(Icons.public),
                ),
                onChanged: (value) => app.updatePreferences((prefs) => prefs.globalApiBaseUrl = value),
              ),
              const SizedBox(height: 12),
              Text(
                'Credentials can be included as http://user:password@host:7860 for --api-auth. '
                'They are never written into exported project files.',
                style: context.text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        );
      },
    );
  }
}
