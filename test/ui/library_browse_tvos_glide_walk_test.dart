import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tvos/flutter_tvos.dart'
    show TvRemoteController, TvRemoteTouchEvent, TvRemoteTouchPhase;
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/repositories/mdblist_repository.dart';
import 'package:moonfin/data/services/background_service.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/browse/library_browse_screen.dart';
import 'package:moonfin/ui/widgets/media_card.dart';
import 'package:moonfin/util/focus/siri_remote_glide.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:moonfin/util/tv_ui_scale.dart';
import 'package:server_core/server_core.dart' hide ImageType;
import 'package:shared_preferences/shared_preferences.dart';

/// Same walk as library_browse_tvos_screen_walk_test, but driven through the
/// app's real Siri Remote glide layer: touchpad drags become bursts of
/// synthesized Down keys, exactly as they do on the device.
void main() {
  const totalItemCount = 600;
  const pageLatency = Duration(milliseconds: 400);

  List<Map<String, dynamic>> pageOf(int startIndex, int limit) => [
    for (var i = startIndex; i < startIndex + limit && i < totalItemCount; i++)
      <String, dynamic>{
        'Id': 'item$i',
        'Name': 'Item ${i.toString().padLeft(3, '0')}',
        'SortName': i.toString().padLeft(6, '0'),
        'Type': 'Movie',
        'ProductionYear': 1990 + (i % 30),
        'UserData': const <String, dynamic>{},
      },
  ];

  final getIt = GetIt.instance;

  // Counts page requests (getItems) so the test can show the frozen grid
  // hammering the server on every eaten Down press.
  var pageRequestCount = 0;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    getIt.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = PreferenceStore();
    await store.init();
    getIt.registerSingleton<UserPreferences>(UserPreferences(store));

    final itemsApi = _MockItemsApi();
    pageRequestCount = 0;
    when(
      () => itemsApi.getItems(
        parentId: any(named: 'parentId'),
        includeItemTypes: any(named: 'includeItemTypes'),
        excludeItemTypes: any(named: 'excludeItemTypes'),
        sortBy: any(named: 'sortBy'),
        sortOrder: any(named: 'sortOrder'),
        startIndex: any(named: 'startIndex'),
        limit: any(named: 'limit'),
        recursive: any(named: 'recursive'),
        fields: any(named: 'fields'),
        enableImageTypes: any(named: 'enableImageTypes'),
        imageTypeLimit: any(named: 'imageTypeLimit'),
        filters: any(named: 'filters'),
        seriesStatus: any(named: 'seriesStatus'),
        isFavorite: any(named: 'isFavorite'),
        ids: any(named: 'ids'),
        genres: any(named: 'genres'),
        officialRatings: any(named: 'officialRatings'),
        tags: any(named: 'tags'),
        years: any(named: 'years'),
        videoTypes: any(named: 'videoTypes'),
        audioLanguages: any(named: 'audioLanguages'),
        subtitleLanguages: any(named: 'subtitleLanguages'),
        hasSubtitles: any(named: 'hasSubtitles'),
        hasTrailer: any(named: 'hasTrailer'),
        hasSpecialFeature: any(named: 'hasSpecialFeature'),
        hasThemeSong: any(named: 'hasThemeSong'),
        hasThemeVideo: any(named: 'hasThemeVideo'),
        isHd: any(named: 'isHd'),
        is4K: any(named: 'is4K'),
        is3D: any(named: 'is3D'),
        collapseBoxSetItems: any(named: 'collapseBoxSetItems'),
      ),
    ).thenAnswer(
      (invocation) => Future<Map<String, dynamic>>.delayed(
        pageLatency,
        () {
          pageRequestCount++;
          final startIndex =
              (invocation.namedArguments[#startIndex] as int?) ?? 0;
          final limit = (invocation.namedArguments[#limit] as int?) ?? 75;
          // Models a library whose later windows only re-deliver items the
          // client has already seen (tied SortNames reordering between
          // requests), while TotalRecordCount still promises more.
          final items = startIndex < 150
              ? pageOf(startIndex, limit)
              : pageOf((startIndex - 100).clamp(0, 149), limit - 4);
          return <String, dynamic>{
            'Items': items,
            'TotalRecordCount': totalItemCount,
          };
        },
      ),
    );
    when(
      () => itemsApi.getItem(any(), fields: any(named: 'fields')),
    ).thenAnswer(
      (invocation) async => <String, dynamic>{
        'Name': 'Movies',
        'CollectionType': 'movies',
      },
    );

    final client = _FakeClient(itemsApi);
    getIt.registerSingleton<MediaServerClientFactory>(
      _FakeClientFactory(client),
    );
    getIt.registerSingleton<MdbListRepository>(_FakeMdbListRepository());
    getIt.registerSingleton<BackgroundService>(BackgroundService());
  });

  tearDown(() async {
    TvRemoteController.instance.debugReset();
    SiriRemoteGlide.instance.debugReset();
    PlatformDetection.setTvMode(false);
    getIt.reset();
  });

  testWidgets(
    'glide drags keep every focused row fully visible',
    (tester) async {
      PlatformDetection.setTvMode(true);
      TvRemoteController.debugForceTvosForTesting = true;
      TvRemoteController.instance.init();
      SiriRemoteGlide.instance.attach();

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TvUiScale(
            child: LibraryBrowseScreen(libraryId: 'lib1'),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));

      final scrollView = find
          .byType(CustomScrollView)
          .evaluate()
          .first
          .findAncestorRenderObjectOfType<RenderBox>()!;
      double viewportBottom() =>
          scrollView.localToGlobal(Offset(0, scrollView.size.height)).dy;

      final log = <String>[];
      var previousCardId = '';
      var stuckDrags = 0;

      // One drag: finger travels down the pad in move events every frame,
      // like a real touchpad drag, then lifts. A full-pad drag is ~2-3 focus
      // steps on medium sensitivity.
      void drag() {
        var y = -0.8;
        TvRemoteController.instance;
        SiriRemoteGlide.instance.debugHandleTouch(
          const TvRemoteTouchEvent(
            phase: TvRemoteTouchPhase.started,
            x: 0,
            y: -0.8,
          ),
        );
        while (y < 0.95) {
          y += 0.12;
          SiriRemoteGlide.instance.debugHandleTouch(
            TvRemoteTouchEvent(phase: TvRemoteTouchPhase.move, x: 0, y: y),
          );
        }
        SiriRemoteGlide.instance.debugHandleTouch(
          const TvRemoteTouchEvent(
            phase: TvRemoteTouchPhase.ended,
            x: 0,
            y: 0.95,
          ),
        );
      }

      for (var gesture = 0; gesture < 60; gesture++) {
        drag();
        // Frames at 60fps while the gesture's synthesized keys land and the
        // follower's 160ms animation runs.
        for (var frame = 0; frame < 16; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        final focusContext = FocusManager.instance.primaryFocus?.context;
        final card = focusContext?.findAncestorWidgetOfExactType<MediaCard>();
        if (card == null) {
          log.add('gesture $gesture: focus left the grid');
          break;
        }
        final cardId = card.title ?? '';
        final cardBox = focusContext!.findRenderObject()! as RenderBox;
        final cardBottom =
            cardBox.localToGlobal(Offset(0, cardBox.size.height)).dy;
        final clip = viewportBottom() - cardBottom;

        if (cardId == previousCardId) {
          stuckDrags++;
        } else {
          stuckDrags = 0;
          previousCardId = cardId;
        }

        if (clip < 1.0) {
          log.add(
            'gesture $gesture ($cardId): focused row bottom is '
            '${clip.toStringAsFixed(1)}px past the viewport bottom',
          );
        }
        if (stuckDrags >= 8) {
          log.add(
            'gesture $gesture: drags stopped moving focus on $cardId '
            '(grid seized)',
          );
          break;
        }
      }

      // Characterize the frozen state: keep pressing Down for another stretch
      // and watch the server take a page request per press while focus never
      // moves again.
      final requestsAtFreeze = pageRequestCount;
      for (var gesture = 0; gesture < 10; gesture++) {
        drag();
        for (var frame = 0; frame < 16; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      final focusContext = FocusManager.instance.primaryFocus?.context;
      final card = focusContext?.findAncestorWidgetOfExactType<MediaCard>();
      final cardBox = focusContext!.findRenderObject()! as RenderBox;
      final cardBottom =
          cardBox.localToGlobal(Offset(0, cardBox.size.height)).dy;
      final clipAfterFreeze = viewportBottom() - cardBottom;
      log.add(
        'frozen on ${card?.title}: bottom is ${clipAfterFreeze
            .toStringAsFixed(1)}px past the viewport bottom, and 10 more '
        'presses took ${pageRequestCount - requestsAtFreeze} more page '
        'requests',
      );

      // Regression: a server whose windows only re-deliver already-seen
      // rows (sort ties reordering between pages) must not freeze the grid
      // with the boundary row clipped off the bottom edge. The stall itself
      // is honest — nothing more will ever load — so 'grid seized' alone is
      // fine; what must not happen is an eaten row.
      expect(
        log.where((entry) => entry.contains('focused row bottom')).length,
        0,
        reason: log.take(40).join('\n'),
      );
      // The frozen row must still be fully revealed...
      expect(clipAfterFreeze >= -1.0, isTrue, reason: log.join('\n'));
      // ...and the grid must stop asking for pages it can never get: the
      // empty-delivery latch bounds the trailing requests to the grace
      // budget, where the unfixed code took one per press forever.
      expect(
        pageRequestCount - requestsAtFreeze <= 4,
        isTrue,
        reason:
            '${pageRequestCount - requestsAtFreeze} page requests after the '
            'grid seized; a latched stream should have stopped asking.\n'
            '${log.join('\n')}',
      );
    },
  );
}

class _MockItemsApi extends Mock implements ItemsApi {}

class _FakeImageApi extends Fake implements ImageApi {}

class _FakeDisplayPreferencesApi extends Fake implements DisplayPreferencesApi {
  @override
  Future<DisplayPreferences> getDisplayPreferences(
    String id, {
    String? client,
  }) async => const DisplayPreferences(id: 'x', customPrefs: {});
}

class _FakeClient extends Fake implements MediaServerClient {
  _FakeClient(this.itemsApi);

  static final _imageApi = _FakeImageApi();
  static final _displayPreferencesApi = _FakeDisplayPreferencesApi();

  @override
  final ItemsApi itemsApi;
  @override
  ImageApi get imageApi => _imageApi;
  @override
  DisplayPreferencesApi get displayPreferencesApi => _displayPreferencesApi;
  @override
  String get baseUrl => 'http://server';
  @override
  String? get accessToken => 'token';
  @override
  String? get userId => 'user1';
}

class _FakeClientFactory extends Fake implements MediaServerClientFactory {
  _FakeClientFactory(this.client);

  final _FakeClient client;

  @override
  MediaServerClient clientForServerOrActive(String? serverId) => client;
}

class _FakeMdbListRepository extends Fake implements MdbListRepository {}
