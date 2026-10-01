import 'package:auto_route/auto_route.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../main_router.dart';
import '../router_test_utils.dart';
import '../nested_router/router.dart';
import '../simple_router/router.dart';
import '../test_page.dart';
import 'router.dart';

/// Records what auto_route reports to the platform through
/// SystemNavigator.setFrameworkHandlesBack
class _BackFlagRecorder {
  final values = <bool>[];

  bool? get last => values.isEmpty ? null : values.last;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
          values.add(call.arguments as bool);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  void clear() => values.clear();
}

void main() {
  for (final tabsType in ['IndexedStack', 'PageView', 'TabBar']) {
    group(tabsType, () => runSystemBackTests(tabsType));
  }

  runNonTabsTests();
}

void runSystemBackTests(String tabsType) {
  late NestedTabsRouter router;
  late _BackFlagRecorder recorder;

  setUp(() {
    router = NestedTabsRouter();
    recorder = _BackFlagRecorder();
  });

  Future<void> pumpRouter(WidgetTester tester, {int homeIndex = -1}) async {
    recorder.install(tester);
    // WidgetsApp drops navigation notifications while its lifecycle state is
    // null and picks the initial one up in initState, so this has to run first
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpRouterConfigApp(
      tester,
      router.config(
        deepLinkBuilder: (_) => DeepLink.single(
          TabsHostRoute(tabsType: tabsType, homeIndex: homeIndex),
        ),
      ),
    );
  }

  TabsRouter tabsRouterOf() => router.innerRouterOf<TabsRouter>(TabsHostRoute.name)!;

  StackRouter tab2RouterOf() => tabsRouterOf().innerRouterOf<StackRouter>(Tab2Route.name)!;

  Future<void> switchTab(WidgetTester tester, int index) async {
    tabsRouterOf().setActiveIndex(index);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  }

  testWidgets(
    'Reported flag follows the active branch, not the last navigator that rebuilt',
    (WidgetTester tester) async {
      await pumpRouter(tester);
      expect(recorder.last, isFalse);

      await switchTab(tester, 1);
      tab2RouterOf().push(Tab2Nested2Route());
      await tester.pumpAndSettle();
      expect(recorder.last, isTrue, reason: 'active tab has a nested route to pop');

      await switchTab(tester, 0);
      expect(recorder.last, isFalse, reason: 'active tab has nothing to pop');

      await switchTab(tester, 1);
      expect(recorder.last, isTrue, reason: 'switched back to the tab that can pop');
    },
  );

  testWidgets(
    'maybePopTop returns false on a non-poppable active tab while another tab is poppable',
    (WidgetTester tester) async {
      await pumpRouter(tester);
      await switchTab(tester, 1);
      final tab2Router = tab2RouterOf();
      tab2Router.push(Tab2Nested2Route());
      await tester.pumpAndSettle();
      expect(tab2Router.stack.length, 2);

      await switchTab(tester, 0);
      expect(await router.maybePopTop(), isFalse);
      await tester.pumpAndSettle();

      expect(tab2Router.stack.length, 2, reason: 'the inactive tab must not be popped');
      expect(tabsRouterOf().activeIndex, 0);
    },
  );

  testWidgets(
    'homeIndex is reported to the platform and switches to the home tab',
    (WidgetTester tester) async {
      await pumpRouter(tester, homeIndex: 0);
      expect(recorder.last, isFalse, reason: 'already on the home tab');

      await switchTab(tester, 1);
      expect(recorder.last, isTrue);

      expect(await router.maybePopTop(), isTrue);
      await tester.pumpAndSettle();
      expect(tabsRouterOf().activeIndex, 0);
    },
  );

  testWidgets(
    'A blocking PopScope in the active branch is reported and swallows the pop',
    (WidgetTester tester) async {
      await pumpRouter(tester);
      await switchTab(tester, 1);
      final tab2Router = tab2RouterOf();
      tab2Router.push(Tab2Nested2Route(blockPop: true));
      await tester.pumpAndSettle();

      expect(recorder.last, isTrue);
      expect(await router.maybePopTop(), isTrue);
      await tester.pumpAndSettle();
      expect(tab2Router.stack.length, 2, reason: 'the PopScope blocks the pop');
    },
  );

  testWidgets(
    'A blocking PopScope in an inactive tab does not block the active branch',
    (WidgetTester tester) async {
      await pumpRouter(tester);
      await switchTab(tester, 1);
      tab2RouterOf().push(Tab2Nested2Route(blockPop: true));
      await tester.pumpAndSettle();

      await switchTab(tester, 0);
      expect(recorder.last, isFalse, reason: 'the blocking route is not on the active branch');
      expect(await router.maybePopTop(), isFalse);
    },
  );

  testWidgets(
    'Every navigation action reports exactly once',
    (WidgetTester tester) async {
      await pumpRouter(tester);
      // master dispatches 7-12 times per action, ending on an arbitrary value,
      // so this guards both the storm and any wrong intermediate value
      void expectReported(bool value) {
        expect(recorder.values, isNotEmpty);
        expect(recorder.values.length, lessThanOrEqualTo(2));
        expect(recorder.values, everyElement(value));
      }

      recorder.clear();
      await switchTab(tester, 1);
      expectReported(false);

      recorder.clear();
      tab2RouterOf().push(Tab2Nested2Route());
      await tester.pumpAndSettle();
      expectReported(true);

      recorder.clear();
      await switchTab(tester, 0);
      expectReported(false);
    },
  );
}

void runNonTabsTests() {
  late _BackFlagRecorder recorder;

  setUp(() => recorder = _BackFlagRecorder());

  Future<void> pumpRouter(WidgetTester tester, RootStackRouter router) async {
    recorder.install(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpRouterApp(tester, router);
  }

  testWidgets(
    'Plain stack reports true after a push and false back at the root',
    (WidgetTester tester) async {
      final router = SimpleRouter();
      await pumpRouter(tester, router);
      expect(recorder.last, isFalse);

      router.push(const SecondRoute());
      await tester.pumpAndSettle();
      expect(recorder.last, isTrue);

      expect(await router.maybePopTop(), isTrue);
      await tester.pumpAndSettle();
      expect(recorder.last, isFalse);
    },
  );

  testWidgets(
    'A PopScope that changes while nothing animates is still reported',
    (WidgetTester tester) async {
      addTearDown(() => FirstPage.blockPop.value = false);
      final router = SimpleRouter();
      await pumpRouter(tester, router);
      expect(recorder.last, isFalse);

      // no navigation happens here, so nothing but the report itself asks for
      // another frame
      FirstPage.blockPop.value = true;
      await tester.pumpAndSettle();
      expect(recorder.last, isTrue, reason: 'the route blocks the pop now');

      FirstPage.blockPop.value = false;
      await tester.pumpAndSettle();
      expect(recorder.last, isFalse, reason: 'and stopped blocking it');
    },
  );

  testWidgets(
    'A nested router inside a single-page root reports true',
    (WidgetTester tester) async {
      final router = NestedRouter();
      await pumpRouter(tester, router);

      router.push(SecondHostRoute());
      await tester.pumpAndSettle();
      final nested = router.innerRouterOf<StackRouter>(SecondHostRoute.name)!;
      nested.push(const SecondNested2Route());
      await tester.pumpAndSettle();

      expect(recorder.last, isTrue);
      expect(await router.maybePopTop(), isTrue);
      await tester.pumpAndSettle();
      expect(nested.stack.length, 1);
    },
  );
}
