// Long HTML pages are parsed off the UI thread and cached by content, and a
// `::preview` widget file loads as its reply renders and says when the
// gateway cut it short, in Classic and NextGen.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/render/contributions_page.dart';
import 'package:hermes_android/core/render/plugin_slots.dart';
import 'package:hermes_android/core/render/rich_transcript.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/hermes_sign_in.dart';
import 'package:hermes_android/core/services/remote_files_client.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/chat_view.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';
import 'support/pump_chat_updates.dart';

const _truncatedNotice =
    'Only the start of this file was read, so the widget may be incomplete.';

SavedConnection _ngConnection(String id) => SavedConnection(
  id: id,
  label: 'Home $id',
  host: '10.0.0.5',
  port: 9119,
  apiKey: 'k',
  desktopGatewayUrl: 'http://10.0.0.5:9119',
  singleLogin: true,
  signInMethod: 'none',
);

/// A page of [target] characters whose sections read "Section n".
String _page(int target) {
  final out = StringBuffer(
    '<!doctype html><html><head><title>Report</title></head><body>\n',
  );
  var i = 0;
  while (out.length < target - 40) {
    out.write('<section><h2>Section $i</h2><p>Row $i grew.</p></section>\n');
    i++;
  }
  out.write('</body></html>');
  return out.toString();
}

class _Files extends RemoteFilesClient {
  _Files(this.html, {this.truncated = false})
    : super(dashboard: DashboardClient(host: '10.0.0.5', port: 9119));

  final String html;
  final bool truncated;
  final reads = <String>[];

  @override
  Future<RemoteTextPreview> readText(String path) async {
    reads.add(path);
    return RemoteTextPreview(
      path: path,
      text: html,
      language: 'html',
      mimeType: 'text/html',
      byteSize: html.length,
      binary: false,
      truncated: truncated,
    );
  }
}

class _Gateway extends NextGenGateway {
  _Gateway(this.files) : super(_ngConnection('c1'));

  final _Files files;

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async => {};

  @override
  RemoteFilesClient createFilesClient({
    String? sessionId,
    int? maxDownloadBytes,
  }) => files;
}

Future<void> _pumpNg(
  WidgetTester tester,
  NextGenGateway gateway,
  NgChatController chat,
) async {
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: nextGenTheme(Brightness.light, NextGenLook.instance),
      home: NgScope(
        connManager: ConnectionManager(prefs),
        gateway: gateway,
        connections: [gateway.connection],
        switchTo: (_) async {},
        addGateway: () async {},
        signOut: (_) async {},
        reload: () async {},
        signInAgain: () async {},
        child: Scaffold(
          body: NgChatView(
            key: ObjectKey(chat),
            chat: chat,
            onOpenSidebar: () {},
            onNewChat: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void _emit(NextGenGateway gateway, String type, [Map<String, dynamic>? data]) =>
    gateway.debugEmit(
      StreamEvent(type: type, data: data ?? const {}, sessionId: 'rt-s'),
    );

class _History extends http.BaseClient {
  _History(this.rows);

  final List<Map<String, dynamic>> rows;

  http.StreamedResponse _json(Object body) => http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode(body))),
    200,
    headers: {'content-type': 'application/json'},
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/messages')) {
      final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
      return _json({'data': offset == 0 ? rows : const []});
    }
    if (request.method == 'GET' && path.startsWith('/api/sessions/')) {
      return _json({
        'session': {'id': path.split('/').last, 'archived': false},
      });
    }
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 404);
  }
}

Widget _classicChat(
  String sessionId,
  List<Map<String, dynamic>> rows,
  _Files files,
) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ChatScreen(
    key: ValueKey(sessionId),
    connection: SavedConnection(
      id: 'classic-fixture',
      label: 'Fixture',
      host: 'fixture.invalid',
      port: 8642,
      apiKey: 'fixture-key',
    ),
    session: Session(
      id: sessionId,
      title: 'Chat $sessionId',
      model: 'fixture',
      source: 'api_server',
      messageCount: rows.length,
      isActive: false,
      preview: '',
      startedAt: 1,
    ),
    testApiClient: ApiClient(
      baseUrl: 'http://fixture.invalid',
      apiKey: 'fixture-key',
      httpClient: _History(rows),
    ),
    testMediaFilesClient: (_) => files,
    testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
  ),
);

/// Lets the background parse of [content] finish in real time, then
/// redraws. The isolate's answer lands in the test zone, so each pump
/// delivers it.
Future<void> _settleParse(WidgetTester tester, String content) async {
  for (var i = 0; i < 200 && !readSandboxedPage(content).ready; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(readSandboxedPage(content).ready, isTrue, reason: 'parse finished');
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(mockChatImageRecovery);
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': true});
    HermesSignInVault.resetForTesting(MemorySignInSecretStore());
    resetSandboxedRenderer();
  });
  tearDown(resetSandboxedRenderer);

  test('short pages parse inline; long ones only in the background', () async {
    readSandboxedPage(_page(2000));
    expect(debugInlinePageParses, 1);
    final long = _page(20 * 1024);
    expect(readSandboxedPage(long).ready, isFalse);
    expect(debugInlinePageParses, 1);
    final first = parseSandboxedPage(long);
    final again = parseSandboxedPage(long);
    expect(identical(first, again), isTrue, reason: 'one parse per content');
    final document = await first;
    expect(document?.text, contains('Section 3'));
    expect(debugBackgroundPageParses, 1);
    expect(readSandboxedPage(long).document, same(document));
    await parseSandboxedPage(long);
    expect(debugBackgroundPageParses, 1, reason: 'cached by content');
  });

  testWidgets('NextGen: a streaming 20 KB page is never parsed per token', (
    tester,
  ) async {
    final gateway = _Gateway(_Files(''));
    addTearDown(gateway.dispose);
    final chat = NgChatController(gateway, sessionId: 's')..runtimeId = 'rt-s';
    chat.debugApplyHistory([
      {'role': 'user', 'content': 'page'},
    ]);
    addTearDown(chat.dispose);
    await _pumpNg(tester, gateway, chat);
    final page = _page(20 * 1024);
    _emit(gateway, 'message.start');
    _emit(gateway, 'message.delta', {'text': 'Page:\n\n```html\n'});
    await tester.pump();
    const parts = 10;
    final step = (page.length / parts).ceil();
    var streamed = '';
    for (var at = 0; at < page.length; at += step) {
      final end = at + step > page.length ? page.length : at + step;
      final chunk = page.substring(at, end);
      streamed += chunk;
      _emit(gateway, 'message.delta', {'text': chunk});
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Only the first 8 KB of the stream was parsed on the UI thread, and
    // background parses were not started once per token.
    expect(debugBackgroundPageParses, lessThanOrEqualTo(2));
    final inlineBefore = debugInlinePageParses;
    await _settleParse(tester, streamed.trim());
    expect(find.textContaining('Section 3', findRichText: true), findsWidgets);
    final parses = debugBackgroundPageParses;
    // A rebuild with the same text reuses the cached page.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(debugBackgroundPageParses, parses);
    expect(debugInlinePageParses, inlineBefore);
    _emit(gateway, 'message.complete', {'status': 'complete'});
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Classic: a 20 KB page shows its source until parsed', (
    tester,
  ) async {
    final page = _page(20 * 1024);
    await tester.pumpWidget(
      MaterialApp(
        theme: hermesTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              content: 'Page:\n\n```html\n$page\n```\n',
              isUser: false,
            ),
          ),
        ),
      ),
    );
    expect(debugInlinePageParses, 0);
    expect(debugBackgroundPageParses, 1);
    await _settleParse(tester, page.trim());
    expect(find.textContaining('Section 3', findRichText: true), findsWidgets);
    await tester.pump();
    expect(debugBackgroundPageParses, 1);
    expect(debugInlinePageParses, 0);
  });

  testWidgets('a 74 KB widget file loads without a UI-thread parse', (
    tester,
  ) async {
    final page = _page(74 * 1024);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SandboxPreviewCard(
              file: 'report.html',
              readHtml: (_) async => WidgetHtmlSource(page),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await _settleParse(tester, page);
    await tester.pump();
    expect(find.textContaining('Section 3', findRichText: true), findsWidgets);
    expect(debugInlinePageParses, 0);
    expect(debugBackgroundPageParses, 1);
    expect(find.text(_truncatedNotice), findsNothing);
  });

  const widgetReply = 'Widget:\n\n::preview{file="w.html"}\n';
  const widgetHtml =
      '<p>Widget body</p><button data-hermes-send="run report">Go</button>';

  testWidgets('NextGen says when the widget file was cut short', (
    tester,
  ) async {
    final gateway = _Gateway(_Files(widgetHtml, truncated: true));
    addTearDown(gateway.dispose);
    final chat = NgChatController(gateway, sessionId: 's')..runtimeId = 'rt-s';
    chat.debugApplyHistory([
      {'role': 'user', 'content': 'show'},
      {'role': 'assistant', 'content': widgetReply},
    ]);
    addTearDown(chat.dispose);
    await _pumpNg(tester, gateway, chat);
    await tester.pump();
    await tester.pump();
    expect(find.text('Widget body'), findsOneWidget);
    expect(find.text(_truncatedNotice), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Classic says when the widget file was cut short', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _classicChat('chat-a', [
        {'id': 1, 'role': 'user', 'content': 'show'},
        {'id': 2, 'role': 'assistant', 'content': widgetReply},
      ], _Files(widgetHtml, truncated: true)),
    );
    await pumpChatUpdates(tester);
    await pumpChatUpdates(tester);
    expect(find.text('Widget body'), findsOneWidget);
    expect(find.text(_truncatedNotice), findsOneWidget);
  });

  testWidgets('a whole widget file shows no truncation notice', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _classicChat('chat-b', [
        {'id': 1, 'role': 'user', 'content': 'show'},
        {'id': 2, 'role': 'assistant', 'content': widgetReply},
      ], _Files(widgetHtml)),
    );
    await pumpChatUpdates(tester);
    await pumpChatUpdates(tester);
    expect(find.text('Widget body'), findsOneWidget);
    expect(find.text(_truncatedNotice), findsNothing);
  });

  // The reply and panel a gateway sent: an absolute host path, a styled
  // page with a drawing, a table and two send buttons.
  const panelReply =
      'Here is a test panel:\n\n'
      '::preview{file="/opt/data/cache/scratch/test-panel.html"}\n\n'
      'Check these in Ares.';
  const panelHtml = '''<!doctype html>
<html><head><meta charset="utf-8"><style>
  th{color:var(--muted-foreground)}
</style></head><body>
<h3>Backup status (test panel)</h3>
<svg width="320" height="20" viewBox="0 0 320 20">
  <rect x="0" y="4" width="48" height="12" rx="6" fill="#e07a3f"/>
</svg>
<table>
  <tr><th>Source</th><th>Backed up</th><th>Status</th></tr>
  <tr><td>max-l5 / Projects</td><td>3.3 GB</td><td>Done</td></tr>
</table>
<button data-hermes-send="refresh the test panel">Refresh</button>
<button data-hermes-send="test panel: list the Gitea repos">Gitea repos</button>
</body></html>''';

  void expectPanel(_Files files) {
    expect(files.reads, ['/opt/data/cache/scratch/test-panel.html']);
    expect(find.textContaining('Backup status (test panel)'), findsOneWidget);
    expect(
      find.textContaining('max-l5 / Projects | 3.3 GB | Done'),
      findsOneWidget,
    );
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Gitea repos'), findsOneWidget);
    expect(find.text('Check these in Ares.'), findsOneWidget);
  }

  testWidgets('NextGen shows a widget as its reply renders, with no tap', (
    tester,
  ) async {
    final files = _Files(panelHtml);
    final gateway = _Gateway(files);
    addTearDown(gateway.dispose);
    final chat = NgChatController(gateway, sessionId: 's')..runtimeId = 'rt-s';
    chat.debugApplyHistory([
      {'role': 'user', 'content': 'show me something as a test'},
      {'role': 'assistant', 'content': panelReply},
    ]);
    addTearDown(chat.dispose);
    await _pumpNg(tester, gateway, chat);
    await tester.pump();
    expectPanel(files);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Classic shows a widget as its reply renders, with no tap', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final files = _Files(panelHtml);
    await tester.pumpWidget(
      _classicChat('chat-panel', [
        {'id': 1, 'role': 'user', 'content': 'show me something as a test'},
        {'id': 2, 'role': 'assistant', 'content': panelReply},
      ], files),
    );
    await pumpChatUpdates(tester);
    expectPanel(files);
  });

  testWidgets('a widget whose file could not be read offers a retry', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SandboxPreviewCard(
            file: '/srv/panel.html',
            // The chat readers answer null for any failed read.
            readHtml: (_) async =>
                ++attempts == 1 ? null : WidgetHtmlSource(widgetHtml),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(attempts, 1);
    expect(
      find.text(
        'Could not load this file. Check the connection and try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('This file is not an HTML widget.'), findsNothing);
    await tester.tap(find.text('Load widget'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('Widget body'), findsOneWidget);
    expect(find.text('Load widget'), findsNothing);
  });

  testWidgets('Contributions names only the slot Ares draws', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ContributionsPage(scope: 'c1\u0000')),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('plugin-slots-notes'))).data,
      'reply cards for ::notes',
    );
    expect(reviewedPlugins.single.directive, 'notes');
  });
}
