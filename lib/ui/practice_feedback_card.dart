import 'package:flutter/material.dart';

import '../practice/practice_feedback.dart';
import '../practice/vietnamese_tone.dart';

class PracticeFeedbackCard extends StatelessWidget {
  const PracticeFeedbackCard({
    super.key,
    required this.feedback,
    required this.onPlayTone,
    this.isPlaying = false,
    this.enabled = true,
  });

  final PracticeFeedback feedback;
  final void Function(PracticeFeedback feedback, ToneGuideItem item) onPlayTone;
  final bool isPlaying;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final paceLabel = _paceLabel(feedback.paceRatio);

    return Card(
      key: const ValueKey<String>('practice-feedback-card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.insights, size: 18, color: colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Shadowing feedback',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  'approximate',
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _MetricChip(label: feedback.wordAccuracyLabel),
                _MetricChip(label: paceLabel),
                if (feedback.toneCheckedCount > 0)
                  _MetricChip(
                    label:
                        'tones ${feedback.toneMatchedCount}/${feedback.toneCheckedCount}',
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              feedback.cadenceSummary,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (feedback.unclearWords.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Words that were unclear or missing',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final word in feedback.unclearWords.take(12))
                    Chip(
                      label: Text(word),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: colorScheme.errorContainer,
                      labelStyle: TextStyle(
                        color: colorScheme.onErrorContainer,
                      ),
                    ),
                  if (feedback.unclearWords.length > 12)
                    Chip(
                      label: Text('+${feedback.unclearWords.length - 12} more'),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            if (feedback.extraWords.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Extra words heard: ${feedback.extraWords.take(8).join(', ')}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
            if (feedback.paceIssues.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Cadence to review',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              for (final issue in feedback.paceIssues)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '${issue.text}: ${issue.ratio >= 1 ? 'held longer' : 'shorter'} '
                    '(${issue.userSeconds.toStringAsFixed(2)}s vs '
                    '${issue.referenceSeconds.toStringAsFixed(2)}s)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
            if (feedback.toneIssues.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Tone contours to review',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              for (final issue in feedback.toneIssues)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.graphic_eq,
                        size: 15,
                        color: colorScheme.tertiary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${issue.text} (${issue.expected.label} '
                          '${issue.expected.arrow}): ${issue.message}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (feedback.toneGuide.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Tone guide — tap a word to hear it',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  if (isPlaying)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  for (final item in feedback.toneGuide)
                    ActionChip(
                      onPressed: !enabled || isPlaying || !item.canPlay
                          ? null
                          : () => onPlayTone(feedback, item),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      label: Text(
                        '${item.text} · ${item.tone.label} ${item.tone.arrow}',
                      ),
                    ),
                ],
              ),
            ],
            if (feedback.note != null) ...[
              const SizedBox(height: 10),
              Text(
                feedback.note!,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _paceLabel(double? ratio) {
    if (ratio == null) {
      return 'pace unknown';
    }

    final percent = ((ratio - 1) * 100).round();

    if (percent.abs() <= 10) {
      return 'pace matched';
    }

    return percent > 0 ? 'pace +$percent%' : 'pace $percent%';
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
