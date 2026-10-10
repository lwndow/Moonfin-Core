import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/widgets/media_card.dart';

/// Reproduction harness for the Apple TV library-browse scroll bug:
/// "when we scroll down through our library, the bottom row gets eaten and
/// eventually stops us from being able to scroll."
///
/// This builds exactly the sliver stack `_buildVerticalGrid` builds, with the
/// television constants (`MediaCard.focusScale` = 1.12 on TV, the design
/// canvas `TvUiScale` lays out on, the dynamic `upwardGrowth` headroom), and
/// then walks focus down the grid with the exact `_scrollToGridRow` follower
/// math the screen uses, one 180ms remote-repeat step per row. Two questions:
///
/// 1. Is `maxScrollExtent` the true content height, or does the sliver's
///    estimate fall short (which would clamp the follower and eat rows)?
/// 2. Does every focused row land fully visible (52px of clearance below it),
///    or does the landing drift progressively further off the bottom?
void main() {
  // The television design canvas from tv_ui_scale.dart, at a 1920-point panel.
  const canvasWidth = 1150.0;
  const canvasHeight = 647.0;
  // _horizontalPadding on a non-mobile browse.
  const gridPadding = 60.0;

  // Builds the same numbers _buildVerticalGrid computes for a poster library
  // of the given poster size, matching the geometry the screen records in
  // _gridGeometry.
  ({int crossAxisCount, double cellWidth, double imageHeight,
      double cellHeight, double upwardGrowth, double rowSpacing,
      double topPadding, double bottomPadding, double spacing})
  screenGeometry({required double posterHeight, required double textHeight}) {
    // _cardWidth() for a poster image type.
    final cardWidth = posterHeight * (2 / 3);
    // spacing on TV with cardFocusExpansion on: MediaCard.focusGap(cardWidth)
    final spacing = MediaCard.focusGap(cardWidth);
    final crossAxisCount =
        ((canvasWidth - gridPadding * 2 + spacing) / (cardWidth + spacing))
            .floor()
            .clamp(2, 20);
    final cellWidth =
        (canvasWidth - gridPadding * 2 - (crossAxisCount - 1) * spacing) /
            crossAxisCount;
    final imageHeight = cellWidth / (2 / 3);
    final cellHeight = imageHeight + textHeight;
    final upwardGrowth = imageHeight * (MediaCard.focusScale - 1);
    final rowSpacing = 16.0 + upwardGrowth;
    final topPadding = 18.0 + upwardGrowth;
    // The clearance _scrollToGridRow demands below a row.
    final bottomPadding = math.max(52.0, upwardGrowth);
    return (
      crossAxisCount: crossAxisCount,
      cellWidth: cellWidth,
      imageHeight: imageHeight,
      cellHeight: cellHeight,
      upwardGrowth: upwardGrowth,
      rowSpacing: rowSpacing,
      topPadding: topPadding,
      bottomPadding: bottomPadding,
      spacing: spacing,
    );
  }

  /// The leading edge of the row holding [index], as gridLineStart computes it
  /// from the geometry the screen records.
  double gridLineStart(
    ({double leadingPad, double lineExtent, double lineSpacing, int perLine})
        geometry,
    int index,
  ) =>
      geometry.leadingPad +
      (index ~/ geometry.perLine) *
          (geometry.lineExtent + geometry.lineSpacing);

  Future<ScrollController> pumpGrid(
    WidgetTester tester, {
    required double posterHeight,
    required double textHeight,
    required int rowCount,
  }) async {
    final g = screenGeometry(
      posterHeight: posterHeight,
      textHeight: textHeight,
    );
    tester.view.physicalSize = const Size(canvasWidth, canvasHeight);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: controller,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  gridPadding,
                  g.topPadding,
                  gridPadding,
                  g.bottomPadding,
                ),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: g.crossAxisCount,
                    mainAxisSpacing: g.rowSpacing,
                    crossAxisSpacing: g.spacing,
                    childAspectRatio: g.cellWidth / g.cellHeight,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        SizedBox.expand(key: ValueKey<int>(index)),
                    childCount: rowCount * g.crossAxisCount,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return controller;
  }

  for (final (posterHeight, textHeight, label) in [
    (150.0, 26.0, 'medium posters, year labels'),
    (150.0, 50.0, 'medium posters, subtitle labels'),
    (210.0, 26.0, 'extra-large posters, year labels'),
  ]) {
    group('tvOS vertical grid: $label', () {
      testWidgets(
        'maxScrollExtent reaches the true content bottom',
        (tester) async {
          const rowCount = 40;
          final controller = await pumpGrid(
            tester,
            posterHeight: posterHeight,
            textHeight: textHeight,
            rowCount: rowCount,
          );
          final g = screenGeometry(
            posterHeight: posterHeight,
            textHeight: textHeight,
          );
          final position = controller.position;
          final viewportHeight = position.viewportDimension;

          final trueContentHeight = g.topPadding +
              rowCount * g.cellHeight +
              (rowCount - 1) * g.rowSpacing +
              g.bottomPadding;
          final trueMax = trueContentHeight - viewportHeight;

          expect(
            position.maxScrollExtent,
            closeTo(trueMax, 1.0),
            reason: 'the sliver stack underestimates its content height: '
                'maxScrollExtent is ${position.maxScrollExtent} but the drawn '
                'content ends at $trueMax, a '
                '${trueMax - position.maxScrollExtent}px shortfall. Rows in '
                'that band can never be scrolled into view.',
          );
        },
      );

      testWidgets(
        'every focused row lands fully visible walking down, last row included',
        (tester) async {
          const rowCount = 40;
          final controller = await pumpGrid(
            tester,
            posterHeight: posterHeight,
            textHeight: textHeight,
            rowCount: rowCount,
          );
          final g = screenGeometry(
            posterHeight: posterHeight,
            textHeight: textHeight,
          );
          final position = controller.position;
          final viewportHeight = position.viewportDimension;

          // _scrollToGridRow, copied from the screen.
          const bottomPad = 52.0;
          void scrollToGridRow(int index) {
            final geometry = (
              perLine: g.crossAxisCount,
              lineExtent: g.cellHeight,
              lineSpacing: g.rowSpacing,
              leadingPad: g.topPadding,
            );
            final rowTop = gridLineStart(geometry, index);
            final rowBottom = rowTop + geometry.lineExtent;
            final current = position.pixels;
            final topPad = geometry.leadingPad;
            var target = current;
            if (rowTop - topPad < current) {
              target = rowTop - topPad;
            } else if (rowBottom + bottomPad > current + viewportHeight) {
              target = rowBottom + bottomPad - viewportHeight;
            }
            target = target.clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            );
            if ((target - current).abs() < 1) return;
            controller.animateTo(
              target,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
            );
          }

          // Walk every row from the top to the bottom the way the remote's
          // 180ms key repeat drives it: one focus step per repeat, frames
          // at 60fps so each leg's 160ms animation actually runs.
          final failures = <String>[];
          for (var row = 0; row < rowCount; row++) {
            final index = row * g.crossAxisCount;
            scrollToGridRow(index);
            for (var frame = 0; frame < 12; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            // Let the final leg settle before measuring.
            if (row == rowCount - 1) {
              await tester.pumpAndSettle();
            }

            final card = find.byKey(ValueKey<int>(index));
            final cardBottom = tester.getBottomLeft(card).dy;
            final below = cardBottom - viewportHeight;
            if (below > 1.0) {
              failures.add(
                'row $row: focused card bottom is $below px below the '
                '$viewportHeight viewport',
              );
            }
          }
          expect(failures, isEmpty, reason: failures.take(12).join('\n'));
        },
      );
    });
  }
}
