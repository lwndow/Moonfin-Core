import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:moonfin/util/platform_detection.dart';
import 'package:moonfin/util/tv_ui_scale.dart';
import 'package:server_core/server_core.dart' hide ImageType;
import 'package:shared_preferences/shared_preferences.dart';

/// Walks the real LibraryBrowseScreen on Apple TV television mode, holding
/// Down the way the Siri remote's native key repeat does (one down event, then
/// repeats every ~180ms, no key-ups), against a server whose pages land with
/// realistic latency. The focused card is supposed to land fully inside the
/// scroll view on every step; on the reported bug the focused row lands lower
/// and lower ("the bottom row gets eaten") until Down stops moving the grid.
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

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    getIt.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = PreferenceStore();
    await store.init();
    getIt.registerSingleton<UserPreferences>(UserPreferences(store));

    final itemsApi = _MockItemsApi();
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
        () => <String, dynamic>{
          'Items': pageOf(
            (invocation.namedArguments[#startIndex] as int?) ?? 0,
            (invocation.namedArguments[#limit] as int?) ?? 75,
          ),
          'TotalRecordCount': totalItemCount,
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
    PlatformDetection.setTvMode(false);
    getIt.reset();
  });

  testWidgets(
    'holding Down keeps every focused row fully visible',
    (tester) async {
      PlatformDetection.setTvMode(true);

      // The real television shell: a 1920x1080 panel, with the app laid out
      // on the design canvas inside TvUiScale's FittedBox (as app.dart does
      // for every TV).
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
      // Let the first page load and the grid build.
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
      var stuckSteps = 0;

      // Hold Down: one down event, then the engine's native repeats every
      // ~180ms, frames at 60fps.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      for (var step = 0; step < 140; step++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        final focusContext = FocusManager.instance.primaryFocus?.context;
        final card = focusContext?.findAncestorWidgetOfExactType<MediaCard>();
        if (card == null) {
          log.add('step $step: focus left the grid');
          break;
        }
        final cardId = card.title ?? '';
        final cardBox = focusContext!.findRenderObject()! as RenderBox;
        final cardBottom =
            cardBox.localToGlobal(Offset(0, cardBox.size.height)).dy;
        final clip = viewportBottom() - cardBottom;

        if (cardId == previousCardId) {
          stuckSteps++;
        } else {
          stuckSteps = 0;
          previousCardId = cardId;
        }

        if (clip < -1.0) {
          log.add(
            'step $step ($cardId): focused row bottom is '
            '${(-clip).toStringAsFixed(1)}px BELOW the viewport',
          );
        } else if (clip < 1.0) {
          log.add(
            'step $step ($cardId): focused row clipped '
            '${clip.toStringAsFixed(1)}px',
          );
        }
        if (stuckSteps >= 10) {
          // The honest end: focus is on the last row of the loaded library.
          break;
        }
      }

      // Let any in-flight page or animation settle, then re-check the last
      // focused card: if it still sits below the viewport, that's the eat.
      await tester.pumpAndSettle(const Duration(seconds: 2));
      final focusContext = FocusManager.instance.primaryFocus?.context;
      final card = focusContext?.findAncestorWidgetOfExactType<MediaCard>();
      if (card != null) {
        final cardBox = focusContext!.findRenderObject()! as RenderBox;
        final cardBottom =
            cardBox.localToGlobal(Offset(0, cardBox.size.height)).dy;
        final clip = viewportBottom() - cardBottom;
        if (clip < 1.0) {
          log.add(
            'after settle (${card.title}): focused row still '
            '${clip.toStringAsFixed(1)}px below the viewport bottom',
          );
        }
      }

      expect(
        log,
        isEmpty,
        reason:
            'The focused row is supposed to land fully visible with room '
            'below it on every Down step, the last row of the library '
            'included.\n${log.take(40).join('\n')}',
      );
      // The walk should have made it to the end of the loaded library.
      expect(
        previousCardId,
        anyOf(isEmpty, isNot('Item 000')),
        reason: 'the walk never left the first card',
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
