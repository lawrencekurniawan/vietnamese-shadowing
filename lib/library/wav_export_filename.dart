import '../text/vietnamese_slug.dart';

const int maxWavTextSlugLength = 60;
const int maxWavVoiceIdLength = 32;
const String wavTextSlugFallback = 'audio';
const String wavVoiceComponentFallback = 'voice';
const String wavFileExtension = '.wav';

/// Builds the deterministic WAV export filename:
///
/// `<text-slug>_<stable-voice-id>_<YYYY-MM-DD>_<HHmmss>.wav`
///
/// [text] must be the original, unnormalized input text. [exportedAt] is
/// rendered in local time; stored metadata timestamps remain UTC.
///
/// [collisionIndex] is zero for the base name. A value of 1 produces `-2`,
/// 2 produces `-3`, and so on.
String buildWavExportFilename({
  required String text,
  required String stableVoiceId,
  DateTime? exportedAt,
  int collisionIndex = 0,
}) {
  final timestamp = (exportedAt ?? DateTime.now()).toLocal();

  final textSlug = vietnameseSlug(
    text,
    maxLength: maxWavTextSlugLength,
    fallback: wavTextSlugFallback,
  );

  final voiceComponent = vietnameseSlug(
    stableVoiceId,
    maxLength: maxWavVoiceIdLength,
    fallback: wavVoiceComponentFallback,
  );

  final baseName =
      '${textSlug}_${voiceComponent}_'
      '${_formatDate(timestamp)}_${_formatTime(timestamp)}$wavFileExtension';

  return applyWavCollisionSuffix(baseName, collisionIndex);
}

/// Adds a collision suffix to an existing WAV filename.
///
/// The function rejects non-WAV names and negative indexes. It never inserts
/// path separators, so callers cannot use it to build a traversal path.
String applyWavCollisionSuffix(String filename, int collisionIndex) {
  if (collisionIndex < 0) {
    throw ArgumentError.value(
      collisionIndex,
      'collisionIndex',
      'must not be negative',
    );
  }

  if (!filename.endsWith(wavFileExtension) ||
      filename.length == wavFileExtension.length) {
    throw ArgumentError.value(filename, 'filename', 'must end with .wav');
  }

  if (filename.contains('/') ||
      filename.contains(r'\') ||
      filename.contains('..') ||
      filename.startsWith('.')) {
    throw ArgumentError.value(
      filename,
      'filename',
      'must be a safe base filename, not a path',
    );
  }

  if (collisionIndex == 0) {
    return filename;
  }

  final stem = filename.substring(0, filename.length - wavFileExtension.length);

  return '$stem-${collisionIndex + 1}$wavFileExtension';
}

String _formatDate(DateTime value) {
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

String _formatTime(DateTime value) {
  return '${value.hour.toString().padLeft(2, '0')}'
      '${value.minute.toString().padLeft(2, '0')}'
      '${value.second.toString().padLeft(2, '0')}';
}
