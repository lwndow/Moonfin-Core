import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screens/browse/library_browse_screen.dart';
import 'package:moonfin/ui/widgets/media_card.dart';

/// The vertical browse grid widens its row pitch and its leading pad to leave
/// a focused card room to grow, and the scroll controller has to land on the
/// lines the sliver really drew. These build the same sliver the screen builds
/// and measure where the cards render, so a start that stops matching the
/// layout fails here instead of walking the focused card off a TV screen.
void main() {
  const viewport = Size(1920, 1080);
  const gridPadding = 48.0;
  const crossSpacing = 12.0;

  /// Lays out the grid the way _buildVerticalGrid does for a card whose
  /// artwork is [imageHeight] tall (plus a [labelHeight] line under it) under
  /// [focusScale], then checks every row in [rows] renders where
  /// gridLineStart says it will.
  Future<void> expectNoDrift(
    WidgetTester tester, {
    required double focusScale,
    required double imageHeight,
    required double labelHeight,
    required int crossAxisCount,
    required List<int> rows,
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The screen's own sums, from _buildVerticalGrid: the focused artwork
    // grows up from its bottomCenter anchor, so the growth is reserved ahead
    // of the grid and between rows, and the grid's trailing padding keeps
    // _scrollToGridRow's clearance (52px) available past the last row.
    final cellHeight = imageHeight + labelHeight;
    final upwardGrowth = imageHeight * (focusScale - 1);
    final GridGeometry geometry = (
      perLine: crossAxisCount,
      lineExtent: cellHeight,
      lineSpacing: 16.0 + upwardGrowth,
      leadingPad: 18.0 + upwardGrowth,
    );
    final bottomPad = math.max(52.0, upwardGrowth);
    final cellWidth =
        (viewport.width -
            gridPadding * 2 -
            (crossAxisCount - 1) * crossSpacing) /
        crossAxisCount;

    // Enough lines past the deepest one under test for it to sit at the top of
    // a full viewport, so no jump is clamped short of where it was aimed.
    final pitch = geometry.lineExtent + geometry.lineSpacing;
    final lineCount =
        rows.reduce(math.max) + 2 + (viewport.height / pitch).ceil();

    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CustomScrollView(
          controller: controller,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                gridPadding,
                geometry.leadingPad,
                gridPadding,
                bottomPad,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: geometry.perLine,
                  mainAxisSpacing: geometry.lineSpacing,
                  crossAxisSpacing: crossSpacing,
                  childAspectRatio: cellWidth / geometry.lineExtent,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) =>
                      SizedBox.expand(key: ValueKey<int>(index)),
                  childCount: lineCount * crossAxisCount,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    for (final row in rows) {
      final card = find.byKey(ValueKey<int>(row * crossAxisCount));
      final start = gridLineStart(geometry, row * crossAxisCount);
      controller.jumpTo(start);
      await tester.pump();

      expect(
        controller.offset,
        closeTo(start, 0.01),
        reason:
            'row $row has to be reachable or the checks below prove nothing',
      );

      final cardTop = tester.getTopLeft(card).dy;
      expect(
        cardTop,
        closeTo(0.0, 0.01),
        reason:
            'row $row rendered ${cardTop}px from where gridLineStart put it',
      );
      // A pitch that only comes out right because the extent and the spacing
      // cancel each other would still leave the row's bottom edge wrong.
      expect(tester.getSize(card).height, closeTo(geometry.lineExtent, 0.01));
    }
  }

  group('grid line starts match the sliver the browse screen builds', () {
    testWidgets('television focus scale, standard poster', (tester) async {
      await expectNoDrift(
        tester,
        focusScale: 1.12,
        imageHeight: 256.0,
        labelHeight: 26.0,
        crossAxisCount: 5,
        rows: const [0, 1, 10, 30, 100, 200],
      );
    });

    testWidgets('desktop focus scale, standard poster', (tester) async {
      await expectNoDrift(
        tester,
        focusScale: 1.05,
        imageHeight: 256.0,
        labelHeight: 26.0,
        crossAxisCount: 6,
        rows: const [0, 1, 10, 50, 200],
      );
    });

    testWidgets('desktop focus scale, large poster', (tester) async {
      await expectNoDrift(
        tester,
        focusScale: 1.05,
        imageHeight: 310.0,
        labelHeight: 50.0,
        crossAxisCount: 6,
        rows: const [0, 10, 100, 200],
      );
    });

    testWidgets('banner layout, few wide cells per line', (tester) async {
      await expectNoDrift(
        tester,
        focusScale: 1.12,
        imageHeight: 154.0,
        labelHeight: 26.0,
        crossAxisCount: 2,
        rows: const [0, 5, 60, 200],
      );
    });

    testWidgets('the focus scale this build was compiled for', (tester) async {
      await expectNoDrift(
        tester,
        focusScale: MediaCard.focusScale,
        imageHeight: 256.0,
        labelHeight: 26.0,
        crossAxisCount: 5,
        rows: const [0, 1, 40, 150],
      );
    });
  });

  test('gridLineStart holds a line together and steps a whole pitch', () {
    // From the television sums: 18.0 leading plus 12% of a 256px artwork.
    const GridGeometry geometry = (
      perLine: 5,
      lineExtent: 282.0,
      lineSpacing: 46.72,
      leadingPad: 48.72,
    );
    const pitch = 282.0 + 46.72;

    expect(gridLineStart(geometry, 0), closeTo(48.72, 0.001));
    expect(gridLineStart(geometry, 4), closeTo(48.72, 0.001));
    expect(gridLineStart(geometry, 5), closeTo(48.72 + pitch, 0.001));
    expect(gridLineStart(geometry, 500), closeTo(48.72 + 100 * pitch, 0.001));
  });
}
