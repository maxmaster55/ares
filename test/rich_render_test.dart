import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_activity.dart';
import 'package:hermes_android/core/render/artifact_library.dart';
import 'package:hermes_android/core/render/plugin_slots.dart';
import 'package:hermes_android/core/render/render_contract.dart';
import 'package:hermes_android/core/render/render_scope.dart';
import 'package:hermes_android/core/render/rich_blocks.dart';
import 'package:hermes_android/core/render/rich_transcript.dart';
import 'package:hermes_android/core/screens/assets_screen.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/chat_assets_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/remote_files_client.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/utils/generated_media.dart';
import 'package:hermes_android/core/widgets/gateway_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/chat_view.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _reply = r'''
> [!NOTE]
> Check the gate

https://www.youtube.com/watch?v=abc123

| Alpha | Beta |
| --- | --- |
| 1 | 2 |

```mermaid
flowchart TD
  Start[Begin] --> EndNode[Finish]
```

```html
<!doctype html>
<html><head><title>Widget draft</title></head><body><p>Hello artifact from the reply.</p></body></html>
```

```listing
{"address":"12 River Road","price":"$1"}
```

::preview{file="note.html"}
''';

/// True when a rendered span containing [needle] has a tap recogniser.
bool _tappableLink(WidgetTester tester, String needle) {
  var found = false;
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    rich.text.visitChildren((span) {
      if (span is TextSpan &&
          span.recognizer is TapGestureRecognizer &&
          (span.text ?? '').contains(needle)) {
        found = true;
      }
      return true;
    });
  }
  return found;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetSandboxedRenderer();
  });

  tearDown(resetSandboxedRenderer);

  test('widget intents require the owning origin and a user gesture', () {
    const token = 'mount-token';
    const origin = 'opaque://widget/note.html';
    final accepted = evaluateWidgetIntent(
      data: {
        'type': intentMessageType,
        'token': token,
        'id': 7,
        'prompt': '  continue please  ',
      },
      token: token,
      nowMs: 5000,
      lastAcceptedAtMs: 0,
      userGesture: true,
      origin: origin,
      expectedOrigin: origin,
    );
    expect(accepted, isA<IntentAccepted>());
    expect((accepted! as IntentAccepted).prompt, 'continue please');

    expect(
      evaluateWidgetIntent(
        data: {
          'type': intentMessageType,
          'token': token,
          'prompt': 'continue please',
        },
        token: token,
        nowMs: 5000,
        lastAcceptedAtMs: 0,
        userGesture: false,
        origin: origin,
        expectedOrigin: origin,
      ),
      isA<IntentRejected>().having((d) => d.error, 'error', 'no_gesture'),
    );
    expect(
      evaluateWidgetIntent(
        data: {
          'type': intentMessageType,
          'token': token,
          'prompt': 'continue please',
        },
        token: token,
        nowMs: 5000,
        lastAcceptedAtMs: 0,
        userGesture: true,
        origin: 'https://evil.test',
        expectedOrigin: origin,
      ),
      isNull,
    );
    expect(
      evaluateWidgetIntent(
        data: {
          'type': intentMessageType,
          'token': token,
          'prompt': 'continue please',
        },
        token: token,
        nowMs: 5500,
        lastAcceptedAtMs: 5000,
        userGesture: true,
        origin: origin,
        expectedOrigin: origin,
      ),
      isA<IntentRejected>().having((d) => d.error, 'error', 'throttled'),
    );
    expect(
      evaluateWidgetIntent(
        data: {
          'type': intentMessageType,
          'token': token,
          'prompt': 'x' * (maxIntentLength + 1),
        },
        token: token,
        nowMs: 8000,
        lastAcceptedAtMs: 5000,
        userGesture: true,
        origin: origin,
        expectedOrigin: origin,
      ),
      isA<IntentRejected>().having((d) => d.error, 'error', 'too_long'),
    );
    expect(
      isPublicDeliveryMessage({
        'role': 'user',
        'content': 'continue please',
        'display_kind': 'hidden',
      }),
      isFalse,
    );
  });

  test('artifact history, links and safe drawings stay bounded', () {
    final history = artifactHistoryFromText('''
```html
<!doctype html><html><head><title>Widget draft</title></head><body><p>one</p></body></html>
```
```html
<!doctype html><html><head><title>Widget draft</title></head><body><p>two</p></body></html>
```
```html
<!doctype html><html><head><title>Widget draft</title></head><body><p>two</p></body></html>
```
''');
    expect(history, hasLength(1));
    expect(history.single.revisions, hasLength(2));
    expect(history.single.revisions.last.downloadName, 'Widget-draft.html');

    final indexed = indexArtifactsFromMessages(
      sessionId: 'chat-1',
      sessionTitle: 'Notes',
      messages: [
        {
          'role': 'assistant',
          'content': 'See https://example.com/docs and /tmp/shot.png',
          'timestamp': 3,
        },
        {
          'role': 'tool',
          'tool_name': 'terminal',
          'content': 'Downloading https://pypi.org/packages/demo/pkg.whl',
          'timestamp': 4,
        },
      ],
    );
    expect(
      indexed.map((item) => item.value),
      containsAll(['https://example.com/docs', '/tmp/shot.png']),
    );
    expect(indexed.any((item) => item.value.endsWith('.whl')), isFalse);

    final diagram = parseMermaid(
      'flowchart TD\n  Start[Begin] --> EndNode[Finish]',
    );
    expect(diagram?.nodes.map((node) => node.label), ['Begin', 'Finish']);
    expect(
      parseSafeSvg(
        '<svg><script>alert(1)</script><rect width="1" height="1"/></svg>',
      ),
      isNull,
    );
    expect(
      parseSafeSvg(
        '<svg viewBox="0 0 10 10"><rect width="4" height="4"/></svg>',
      ),
      isNotNull,
    );
    expect(
      parseListings('{"address":"12 River Road"}').single.address,
      '12 River Road',
    );
    // Provider links are ordinary prose: Ares embeds no third-party player.
    expect(
      splitRichProse('https://www.youtube.com/watch?v=abc123').single,
      isA<ProsePiece>(),
    );
    expect(
      parseSandboxedHtml('<p>Safe</p><script>alert(1)</script>')?.text,
      'Safe',
    );
    expect(
      parseSandboxedHtml(
        '<p>Safe</p><script>alert(1)</script>',
      )?.droppedActiveContent,
      isTrue,
    );
    // One row per line, cells split, the source's indentation dropped.
    expect(
      parseSandboxedHtml(
        '<table>\n  <tr><th>Source</th><th>Status</th></tr>\n'
        '  <tr><td>Projects</td><td>Done</td></tr>\n</table>',
      )?.text,
      'Source | Status\nProjects | Done',
    );
  });

  test('an unreviewed package cannot receive a slot', () {
    expect(pluginGrants.grant('c1', 'remote.example'), isFalse);
    expect(pluginGrants.granted('c1', 'remote.example'), isFalse);
    expect(pluginGrants.grant('c1', 'notes'), isTrue);
    expect(pluginGrants.showsDirective('c1', 'notes'), isTrue);
    expect(pluginGrants.showsDirective('c2', 'notes'), isFalse);
    pluginGrants.revoke('c1', 'notes');
    expect(pluginGrants.showsDirective('c1', 'notes'), isFalse);
  });

  testWidgets('Classic renders rich replies without running widget script', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prompts = <String>[];
    await tester.pumpWidget(
      _app(
        theme: hermesTheme(Brightness.light),
        child: MessageBubble(
          content: _reply,
          isUser: false,
          readWidgetHtml: (_) async => WidgetHtmlSource(
            '<p>Safe copy</p><script>alert(1)</script>'
            '<button data-hermes-send="continue please">Go</button>',
          ),
          onWidgetIntent: (prompt) async => prompts.add(prompt),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Check the gate'), findsOneWidget);
    expect(find.text('Begin'), findsOneWidget);
    expect(find.text('Widget draft'), findsOneWidget);
    expect(find.text('12 River Road'), findsOneWidget);
    expect(find.text('Load once'), findsNothing);
    expect(_tappableLink(tester, 'youtube.com/watch?v=abc123'), isTrue);
    expect(find.text('alert(1)'), findsNothing);

    await tester.pump();
    expect(find.text('Safe copy'), findsOneWidget);
    expect(find.text('alert(1)'), findsNothing);
    expect(
      find.text('Scripts, frames and external addresses were removed.'),
      findsWidgets,
    );
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(prompts, ['continue please']);
    expect(find.text('Sent to this chat'), findsOneWidget);
    await tester.tap(find.text('Go'));
    await tester.pump();
    // The refusal code `throttled`, worded.
    expect(find.text('Wait a moment before sending again'), findsOneWidget);
    expect(prompts, ['continue please']);
  });

  testWidgets('NextGen uses the same rich reply controls', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final connection = SavedConnection(
      id: 'c1',
      label: 'Home',
      host: '127.0.0.1',
      port: 9,
      apiKey: '',
      desktopGatewayUrl: 'http://127.0.0.1:9',
      singleLogin: true,
      signInMethod: 'none',
    );
    final gateway = NextGenGateway(connection);
    final chat = NgChatController(gateway, sessionId: 'stored')
      ..runtimeId = 'stored';
    chat.debugApplyHistory([
      {'role': 'assistant', 'content': _reply, 'id': 'a1'},
      {
        'role': 'assistant',
        'content': '',
        'id': 'a2',
        'tool_calls': [
          {
            'id': 'call-1',
            'function': {'name': 'vision_analyze', 'arguments': '{}'},
          },
        ],
      },
      {
        'role': 'tool',
        'tool_call_id': 'call-1',
        'content': 'Screenshot path: /tmp/shot.png',
      },
    ]);
    addTearDown(() {
      chat.dispose();
      gateway.dispose();
    });
    await tester.pumpWidget(
      _app(
        theme: nextGenTheme(Brightness.light, NextGenLook.instance),
        bounded: true,
        child: NgScope(
          connManager: ConnectionManager(prefs),
          gateway: gateway,
          connections: [connection],
          switchTo: (_) async {},
          addGateway: () async {},
          signOut: (_) async {},
          reload: () async {},
          signInAgain: () async {},
          child: NgChatView(chat: chat),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Check the gate'), findsOneWidget);
    expect(find.text('Begin'), findsOneWidget);
    expect(find.text('Widget draft'), findsOneWidget);
    expect(find.text('Load once'), findsNothing);
    expect(_tappableLink(tester, 'youtube.com/watch?v=abc123'), isTrue);
    final used = find.text('Used vision_analyze');
    await tester.ensureVisible(used);
    await tester.tap(used);
    await tester.pump();
    final tool = find.text('vision_analyze');
    await tester.ensureVisible(tool);
    await tester.tap(tool);
    await tester.pump();
    expect(find.text('Inspected image'), findsOneWidget);
    expect(find.text('shot.png'), findsOneWidget);
  });

  testWidgets('markdown table columns can be dragged', (tester) async {
    await tester.pumpWidget(
      _app(
        theme: hermesTheme(Brightness.light),
        child: const ResizableMarkdownTable(
          table: TablePiece(
            ['Alpha', 'Beta'],
            [
              ['1', '2'],
            ],
          ),
        ),
      ),
    );
    final before = tester.getSize(find.byKey(const Key('table-col-0'))).width;
    await tester.drag(
      find.byKey(const Key('table-resize-0')),
      const Offset(40, 0),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const Key('table-col-0'))).width,
      greaterThan(before),
    );
  });

  testWidgets('Classic tool rows show an inspected image', (tester) async {
    await tester.pumpWidget(
      _app(
        theme: hermesTheme(Brightness.light),
        child: GatewayActivityCard(
          pinnedExpansion: true,
          activities: [
            GatewayToolActivity(
              name: 'vision_analyze',
              phase: GatewayToolActivityPhase.completed,
              detail: 'Screenshot path: /tmp/shot.png',
            ),
          ],
        ),
      ),
    );
    expect(find.text('Inspected image'), findsOneWidget);
    expect(find.text('shot.png'), findsOneWidget);
  });

  testWidgets(
    'Assets indexes ordinary links and contributions can be granted',
    (tester) async {
      final session = Session(
        id: 's1',
        title: 'Notes',
        model: 'test',
        source: 'cli',
        messageCount: 1,
        isActive: false,
        preview: '',
        startedAt: 10,
      );
      await tester.pumpWidget(
        _app(
          theme: hermesTheme(Brightness.light),
          bounded: true,
          child: AssetsScreen(
            source: _Source(
              sessions: [session],
              messages: {
                's1': [
                  {
                    'role': 'assistant',
                    'content': 'Read https://example.com/docs',
                    'timestamp': 20,
                  },
                ],
              },
            ),
            filesClient: (_) => _Files(),
            onOpenSession: (_) {},
            contributionsScope: 'c1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('example.com'), findsNothing);
      expect(find.text('docs'), findsOneWidget);
      await tester.ensureVisible(find.text('Links'));
      await tester.tap(find.text('Links'));
      await tester.pump();
      expect(find.text('https://example.com/docs'), findsOneWidget);

      await tester.tap(find.byTooltip('Contributions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grant Notes'));
      await tester.pump();
      expect(find.text('Revoke Notes'), findsOneWidget);
      expect(pluginGrants.granted('c1', 'notes'), isTrue);
      expect(pluginGrants.granted('c2', 'notes'), isFalse);
    },
  );

  testWidgets('a granted directive renders only on its own connection', (
    tester,
  ) async {
    pluginGrants.grant('c1', 'notes');
    Widget bubble(String connection) => _app(
      theme: nextGenTheme(Brightness.light, NextGenLook.instance),
      child: RenderScope(
        connection: connection,
        chat: 'stored',
        child: const MessageBubble(
          content: '::notes{text="Remember the milk"}',
          isUser: false,
        ),
      ),
    );
    await tester.pumpWidget(bubble('c1'));
    expect(find.text('Notes directive'), findsOneWidget);
    expect(find.text('Remember the milk'), findsOneWidget);
    await tester.pumpWidget(bubble('c2'));
    expect(find.text('Notes directive'), findsNothing);
    expect(find.text('::notes{text="Remember the milk"}'), findsOneWidget);
  });
}

Widget _app({
  required ThemeData theme,
  required Widget child,
  bool bounded = false,
}) {
  return MaterialApp(
    theme: theme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: bounded ? child : SingleChildScrollView(child: child)),
  );
}

class _Source implements ChatAssetsDataSource {
  _Source({required this.sessions, required this.messages});

  final List<Session> sessions;
  final Map<String, List<Map<String, dynamic>>> messages;

  @override
  Future<ChatAssetsSessionPage> listSessions({
    int offset = 0,
    int limit = 10,
  }) async {
    return ChatAssetsSessionPage(
      sessions: sessions,
      nextOffset: offset + limit,
      hasMore: false,
      partial: false,
    );
  }

  @override
  Future<ChatAssetsMessagePage> getMessages(
    Session session, {
    int offset = 0,
    int limit = 100,
  }) async {
    return ChatAssetsMessagePage(
      messages: messages[session.id] ?? const [],
      nextOffset: offset + limit,
      hasMore: false,
    );
  }
}

class _Files implements RemoteFilesDataSource {
  @override
  Future<RemoteDirectory> defaultDirectory() => throw UnimplementedError();

  @override
  Future<RemoteFileDownload> download(String path) =>
      throw UnimplementedError();

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) =>
      throw UnimplementedError();

  @override
  Future<RemoteTextPreview> readText(String path) => throw UnimplementedError();
}
