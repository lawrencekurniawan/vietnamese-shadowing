import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/library/library_metadata.dart';
import 'package:vietnamese_shadowing/ui/library_item_card.dart';

void main() {
  final item = LibraryItemMetadata(
    itemId: '123e4567-e89b-42d3-a456-426614174000',
    title: 'Xin chào',
    originalText: 'Xin chào, thế giới!',
    normalizedText: 'xin chào, thế giới!',
    voice: VoiceMetadata(
      stableId: 'mai-anh',
      presetName: 'Mai Anh',
      displayName: 'Mai Anh',
      description: 'Nữ · Bắc · Phong cách tự nhiên',
      gender: 'female',
      accent: 'Bắc',
      style: 'tu_nhien',
    ),
    createdAtUtc: DateTime.utc(2026, 10, 20, 12),
    audio: AudioMetadata(
      sampleRate: 48000,
      channels: 1,
      bitDepth: 16,
      durationSeconds: 1.28,
    ),
  );

  testWidgets('wires rename, delete, export, play, and stop actions', (
    tester,
  ) async {
    var playCalls = 0;
    var stopCalls = 0;
    var renameCalls = 0;
    var deleteCalls = 0;
    var exportWavCalls = 0;
    var exportVshadowCalls = 0;

    Widget buildCard({required bool isCurrent, required bool isPlaying}) {
      return MaterialApp(
        home: Scaffold(
          body: LibraryItemCard(
            item: item,
            isCurrent: isCurrent,
            isPlaying: isPlaying,
            onPlay: () => playCalls++,
            onStop: () => stopCalls++,
            onRename: () => renameCalls++,
            onDelete: () => deleteCalls++,
            onExportWav: () => exportWavCalls++,
            onExportVshadow: () => exportVshadowCalls++,
          ),
        ),
      );
    }

    await tester.pumpWidget(buildCard(isCurrent: false, isPlaying: false));

    expect(find.text('Xin chào'), findsOneWidget);
    expect(find.textContaining('Bắc'), findsOneWidget);
    expect(find.textContaining('1.3s'), findsOneWidget);

    await tester.tap(find.byKey(playKey));
    await tester.tap(find.byKey(renameKey));
    await tester.tap(find.byKey(deleteKey));
    await tester.tap(find.byKey(exportWavKey));
    await tester.tap(find.byKey(exportVshadowKey));

    expect(playCalls, 1);
    expect(renameCalls, 1);
    expect(deleteCalls, 1);
    expect(exportWavCalls, 1);
    expect(exportVshadowCalls, 1);
    expect(stopCalls, 0);

    await tester.pumpWidget(buildCard(isCurrent: true, isPlaying: true));
    await tester.tap(find.byKey(playKey));

    expect(stopCalls, 1);
    expect(playCalls, 1);
  });

  testWidgets('disables play while a different item is playing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryItemCard(
            item: item,
            isCurrent: false,
            isPlaying: true,
            onPlay: () {},
            onStop: () {},
            onRename: () {},
            onDelete: () {},
            onExportWav: () {},
            onExportVshadow: () {},
          ),
        ),
      ),
    );

    final button = tester.widget<OutlinedButton>(find.byKey(playKey));
    expect(button.onPressed, isNull);
  });
}

const playKey = ValueKey<String>(
  'library-play-123e4567-e89b-42d3-a456-426614174000',
);
const renameKey = ValueKey<String>(
  'library-rename-123e4567-e89b-42d3-a456-426614174000',
);
const deleteKey = ValueKey<String>(
  'library-delete-123e4567-e89b-42d3-a456-426614174000',
);
const exportWavKey = ValueKey<String>(
  'library-export-wav-123e4567-e89b-42d3-a456-426614174000',
);
const exportVshadowKey = ValueKey<String>(
  'library-export-vshadow-123e4567-e89b-42d3-a456-426614174000',
);
