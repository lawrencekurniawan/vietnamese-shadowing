/// One short conversational passage that can be converted to speech and
/// shadowed in the Practice tab.
class ConversationLine {
  const ConversationLine({
    required this.id,
    required this.displayText,
    required this.sourceTitle,
    required this.sourceDetail,
    this.speechText,
    this.rating,
    this.downloadCount,
    this.isOnline = false,
  });

  factory ConversationLine.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final displayText = json['display_text'];
    final sourceTitle = json['source_title'];
    final sourceDetail = json['source_detail'];

    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('Conversation line ID is missing.');
    }

    if (displayText is! String || displayText.trim().isEmpty) {
      throw const FormatException('Conversation line text is missing.');
    }

    if (sourceTitle is! String || sourceTitle.trim().isEmpty) {
      throw const FormatException('Conversation source title is missing.');
    }

    if (sourceDetail is! String || sourceDetail.trim().isEmpty) {
      throw const FormatException('Conversation source detail is missing.');
    }

    final rating = json['rating'];
    final downloadCount = json['download_count'];
    final speechText = json['speech_text'];
    final isOnline = json['is_online'];

    return ConversationLine(
      id: id.trim(),
      displayText: displayText.trim(),
      speechText: speechText is String && speechText.trim().isNotEmpty
          ? speechText.trim()
          : null,
      sourceTitle: sourceTitle.trim(),
      sourceDetail: sourceDetail.trim(),
      rating: rating is num && rating.isFinite ? rating.toDouble() : null,
      downloadCount: downloadCount is int && downloadCount >= 0
          ? downloadCount
          : null,
      isOnline: isOnline == true,
    );
  }

  final String id;

  /// Text shown to the user. It may contain line breaks for a short exchange.
  final String displayText;

  /// Text sent to the text-to-speech engine. Defaults to [displayText] with
  /// line breaks folded into spaces.
  final String? speechText;

  /// Human-readable source, usually a film or television title.
  final String sourceTitle;

  /// Download/rating/attribution details shown under the passage.
  final String sourceDetail;

  final double? rating;
  final int? downloadCount;
  final bool isOnline;

  String get textForSpeech =>
      (speechText ?? displayText).replaceAll(RegExp(r'\s+'), ' ').trim();

  String get suggestedLibraryTitle {
    final clean = textForSpeech;
    final snippet = clean.length <= 54
        ? clean
        : '${clean.substring(0, 51).trimRight()}...';

    return '${sourceTitle.trim()} — $snippet';
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'display_text': displayText,
      'source_title': sourceTitle,
      'source_detail': sourceDetail,
      if (speechText != null) 'speech_text': speechText,
      if (rating != null) 'rating': rating,
      if (downloadCount != null) 'download_count': downloadCount,
      'is_online': isOnline,
    };
  }
}
