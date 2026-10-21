import 'package:flutter/material.dart';

import '../library/library_metadata.dart';

/// One saved library item and its actions.
class LibraryItemCard extends StatelessWidget {
  const LibraryItemCard({
    super.key,
    required this.item,
    required this.isCurrent,
    required this.isPlaying,
    required this.onPlay,
    required this.onStop,
    required this.onRename,
    required this.onDelete,
    required this.onExportWav,
    required this.onExportVshadow,
  });

  final LibraryItemMetadata item;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onStop;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onExportWav;
  final VoidCallback onExportVshadow;

  String get _details {
    final duration = _formatLibraryDuration(item.audio.durationSeconds);
    final parts = <String>[
      item.voice.accent,
      item.voice.displayName,
      _formatLibraryTimestamp(item.createdAtUtc),
      if (duration.isNotEmpty) duration,
    ];

    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final isCurrentPlaying = isCurrent && isPlaying;

    return Card(
      key: ValueKey<String>('library-card-${item.itemId}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: ValueKey<String>('library-rename-${item.itemId}'),
                  tooltip: 'Rename',
                  onPressed: onRename,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
                IconButton(
                  key: ValueKey<String>('library-delete-${item.itemId}'),
                  tooltip: 'Delete',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ],
            ),
            Text(_details, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              item.originalText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: ValueKey<String>('library-play-${item.itemId}'),
                  onPressed: isCurrentPlaying
                      ? onStop
                      : isPlaying
                      ? null
                      : onPlay,
                  icon: Icon(
                    isCurrentPlaying ? Icons.stop : Icons.play_arrow,
                    size: 18,
                  ),
                  label: Text(isCurrentPlaying ? 'Stop' : 'Play'),
                ),
                OutlinedButton.icon(
                  key: ValueKey<String>('library-export-wav-${item.itemId}'),
                  onPressed: onExportWav,
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Export WAV'),
                ),
                OutlinedButton.icon(
                  key: ValueKey<String>(
                    'library-export-vshadow-${item.itemId}',
                  ),
                  onPressed: onExportVshadow,
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text('Export .vshadow'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatLibraryTimestamp(DateTime value) {
  final local = value.toLocal();

  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String _formatLibraryDuration(double? seconds) {
  if (seconds == null) {
    return '';
  }

  final precision = seconds >= 10 ? 0 : 1;
  return '${seconds.toStringAsFixed(precision)}s';
}
