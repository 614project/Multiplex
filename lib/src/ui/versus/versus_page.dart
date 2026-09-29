import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/sd_client.dart';
import '../../core/image_timestamps.dart';
import '../../state/app_state.dart';
import '../../state/cell_model.dart';
import '../../state/project_session.dart';
import '../../state/versus_tournament.dart';
import '../common/cell_image.dart';
import '../platform_actions.dart';
import '../theme.dart';

/// Pick the best image of a cell through a single-elimination tournament.
class VersusPage extends StatefulWidget {
  const VersusPage({super.key, required this.session, required this.cell, required this.images});

  final ProjectSession session;
  final CellModel cell;
  final List<CellImage> images;

  @override
  State<VersusPage> createState() => _VersusPageState();
}

class _VersusPageState extends State<VersusPage> {
  late final VersusTournament _tournament = VersusTournament([
    for (final image in widget.images) VersusParticipant(image.path, image.createdAt),
  ]);

  @override
  void dispose() {
    _tournament.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final winner = _tournament.winner;
    if (winner == null) {
      return;
    }

    final app = context.read<AppState>();
    try {
      final message = await PlatformActions.saveImages([winner.path]);
      if (message != null) {
        app.messenger.success(message);
      }
    } catch (error) {
      app.messenger.error('Saving failed: ${SdClient.describeError(error)}');
    }
  }

  void _setRepresentative() {
    final winner = _tournament.winner;
    if (winner == null) {
      return;
    }

    widget.session.setRepresentativeImage(widget.cell, winner.path);
    context.read<AppState>().messenger.success(
      'The winner is now the representative image of ${widget.cell.displayName}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _tournament,
      builder: (context, _) {
        final completed = _tournament.isCompleted;
        final total = _tournament.totalMatches;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): _tournament.chooseLeft,
            const SingleActivator(LogicalKeyboardKey.arrowUp): _tournament.chooseLeft,
            const SingleActivator(LogicalKeyboardKey.digit1): _tournament.chooseLeft,
            const SingleActivator(LogicalKeyboardKey.arrowRight): _tournament.chooseRight,
            const SingleActivator(LogicalKeyboardKey.arrowDown): _tournament.chooseRight,
            const SingleActivator(LogicalKeyboardKey.digit2): _tournament.chooseRight,
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: AppBar(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Versus · ${widget.cell.displayName}'),
                    Text(
                      _tournament.statusText,
                      style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                  ],
                ),
                actions: [
                  IconButton(
                    tooltip: 'Restart',
                    onPressed: () => _tournament.restart(),
                    icon: const Icon(Icons.restart_alt),
                  ),
                ],
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(4),
                  child: LinearProgressIndicator(value: total == 0 ? 1 : _tournament.playedMatches / total),
                ),
              ),
              body: completed ? _Result(tournament: _tournament) : _Match(tournament: _tournament),
              bottomNavigationBar: completed
                  ? SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _tournament.restart(),
                              icon: const Icon(Icons.restart_alt),
                              label: const Text('Retry'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _save,
                              icon: const Icon(Icons.download),
                              label: const Text('Save'),
                            ),
                            FilledButton.icon(
                              onPressed: _setRepresentative,
                              icon: const Icon(Icons.star),
                              label: const Text('Set representative'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : null,
            ),
          ),
        );
      },
    );
  }
}

class _Match extends StatelessWidget {
  const _Match({required this.tournament});

  final VersusTournament tournament;

  @override
  Widget build(BuildContext context) {
    final left = tournament.left;
    final right = tournament.right;
    if (left == null || right == null) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final vertical = constraints.maxHeight > constraints.maxWidth;
        final children = [
          Expanded(
            child: _Contender(
              key: ValueKey('left-${left.path}'),
              participant: left,
              hint: vertical ? 'Tap to pick' : 'Click or press ←',
              onPick: tournament.chooseLeft,
            ),
          ),
          SizedBox(width: vertical ? 0 : 12, height: vertical ? 12 : 0),
          Expanded(
            child: _Contender(
              key: ValueKey('right-${right.path}'),
              participant: right,
              hint: vertical ? 'Tap to pick' : 'Click or press →',
              onPick: tournament.chooseRight,
            ),
          ),
        ];
        return Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: vertical ? Column(children: children) : Row(children: children),
            ),
            IgnorePointer(
              child: Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: context.colors.primary,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 12)],
                ),
                child: Text(
                  'VS',
                  style: context.text.titleMedium?.copyWith(
                    color: context.colors.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Contender extends StatelessWidget {
  const _Contender({super.key, required this.participant, required this.hint, required this.onPick});

  final VersusParticipant participant;
  final String hint;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.94, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPick,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: FileThumbnail(path: participant.path, fit: BoxFit.contain),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        ImageTimestamps.format(participant.createdAt),
                        style: context.text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                    Icon(Icons.touch_app_outlined, size: 16, color: colors.primary),
                    const SizedBox(width: 6),
                    Text(hint, style: context.text.labelMedium?.copyWith(color: colors.primary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.tournament});

  final VersusTournament tournament;

  @override
  Widget build(BuildContext context) {
    final winner = tournament.winner;
    final colors = context.colors;
    if (winner == null) {
      return const Center(child: Text('Select at least two images to start a tournament.'));
    }

    final winnerView = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.emoji_events, color: Colors.amber.shade600, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Winner', style: context.text.headlineSmall),
                  Text(
                    winner.path.split(RegExp(r'[\\/]')).last,
                    style: context.text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: ColoredBox(
              color: colors.surfaceContainerLow,
              child: FileThumbnail(path: winner.path, fit: BoxFit.contain),
            ),
          ),
        ),
      ],
    );

    final ranking = ListView.separated(
      itemCount: tournament.results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final participant = tournament.results[index];
        return Card(
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox.square(dimension: 52, child: FileThumbnail(path: participant.path, decodeWidth: 52)),
            ),
            title: Text(participant.resultText),
            subtitle: Text(ImageTimestamps.format(participant.createdAt)),
            trailing: participant.isWinner
                ? Icon(Icons.emoji_events, color: Colors.amber.shade600)
                : Text('#${index + 1}'),
          ),
        );
      },
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 2, child: winnerView),
                const SizedBox(width: 20),
                Expanded(child: ranking),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 3, child: winnerView),
              const SizedBox(height: 16),
              Expanded(flex: 2, child: ranking),
            ],
          ),
        );
      },
    );
  }
}
