import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/ui/home_tab_scaffold.dart';

void main() {
  testWidgets('keeps both tabs alive while switching', (tester) async {
    var selectedTab = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return HomeTabScaffold(
              selectedTab: selectedTab,
              onTabSelected: (index) {
                setState(() {
                  selectedTab = index;
                });
              },
              generateTab: const _Counter(
                key: ValueKey<String>('generate-child'),
                countKey: ValueKey<String>('generate-count'),
                buttonKey: ValueKey<String>('generate-increment'),
              ),
              libraryTab: const _Counter(
                key: ValueKey<String>('library-child'),
                countKey: ValueKey<String>('library-count'),
                buttonKey: ValueKey<String>('library-increment'),
              ),
              isPlaying: false,
              onStopPlayback: () {},
            );
          },
        ),
      ),
    );

    expect(_indexedStack(tester).index, 0);

    await tester.tap(find.byKey(const ValueKey<String>('generate-increment')));
    await tester.pump();
    expect(_counterText(tester, 'generate-count'), '1');

    await tester.tap(find.byKey(HomeTabScaffold.libraryTabKey));
    await tester.pump();

    expect(_indexedStack(tester).index, 1);
    expect(find.widgetWithText(AppBar, 'Library'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('library-increment')));
    await tester.pump();
    expect(_counterText(tester, 'library-count'), '1');

    await tester.tap(find.byKey(HomeTabScaffold.generateTabKey));
    await tester.pump();

    expect(_indexedStack(tester).index, 0);
    expect(find.widgetWithText(AppBar, 'Vietnamese Shadowing'), findsOneWidget);
    expect(_counterText(tester, 'generate-count'), '1');

    await tester.tap(find.byKey(HomeTabScaffold.libraryTabKey));
    await tester.pump();

    expect(_indexedStack(tester).index, 1);
    expect(_counterText(tester, 'library-count'), '1');
  });

  testWidgets('exposes a global stop action while audio is playing', (
    tester,
  ) async {
    var stops = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: HomeTabScaffold(
          selectedTab: 0,
          onTabSelected: (_) {},
          generateTab: const SizedBox.shrink(),
          libraryTab: const SizedBox.shrink(),
          isPlaying: true,
          onStopPlayback: () {
            stops++;
          },
        ),
      ),
    );

    await tester.tap(find.byKey(HomeTabScaffold.stopPlaybackKey));
    await tester.pump();

    expect(stops, 1);
  });
}

IndexedStack _indexedStack(WidgetTester tester) {
  return tester.widget<IndexedStack>(find.byType(IndexedStack));
}

String? _counterText(WidgetTester tester, String key) {
  return tester.widget<Text>(find.byKey(ValueKey<String>(key))).data;
}

class _Counter extends StatefulWidget {
  const _Counter({super.key, required this.countKey, required this.buttonKey});

  final Key countKey;
  final Key buttonKey;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('$_count', key: widget.countKey),
        TextButton(
          key: widget.buttonKey,
          onPressed: () {
            setState(() {
              _count++;
            });
          },
          child: const Text('Increment'),
        ),
      ],
    );
  }
}
