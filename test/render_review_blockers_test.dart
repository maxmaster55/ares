// Regressions for the independent review of the rich renderer (v5/render).
// Each group names the review blocker it covers. The file uses only APIs that
// existed before the fix, so the same cases show red on the reviewed tree.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_activity.dart';
import 'package:hermes_android/core/render/artifact_library.dart';
import 'package:hermes_android/core/render/plugin_slots.dart';
import 'package:hermes_android/core/render/rich_blocks.dart';
import 'package:hermes_android/core/render/rich_transcript.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/hermes_sign_in.dart';
import 'package:hermes_android/core/services/remote_files_client.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/utils/media_tags.dart';
import 'package:hermes_android/core/widgets/gateway_activity_card.dart';
import 'package:hermes_android/core/widgets/media_artifact_card.dart';
import 'package:hermes_android/core/workspace/workspace_registry.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/chat_view.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pump_chat_updates.dart';

const _frameBudgetMs = 50;

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: 'Home $id',
  host: '10.0.0.5',
  port: 9119,
  apiKey: 'k',
  desktopGatewayUrl: 'http://10.0.0.5:9119',
  singleLogin: true,
  signInMethod: 'none',
);

/// Times one cold call: caches are cleared first, and the function has
/// already been compiled on a tiny input.
int _coldMs(void Function() warm, void Function() body) {
  warm();
  resetSandboxedRenderer();
  final watch = Stopwatch()..start();
  body();
  return watch.elapsedMilliseconds;
}

class _WidgetFiles extends RemoteFilesClient {
  _WidgetFiles(this.html)
    : super(dashboard: DashboardClient(host: '10.0.0.5', port: 9119));

  final String html;

  @override
  Future<RemoteTextPreview> readText(String path) async => RemoteTextPreview(
    path: path,
    text: html,
    language: 'html',
    mimeType: 'text/html',
    byteSize: html.length,
    binary: false,
    truncated: false,
  );
}

/// Records prompt submissions; [hold] keeps a submission in flight.
class _IntentGateway extends NextGenGateway {
  _IntentGateway() : super(_connection('c1'));

  final submits = <String>[];
  Completer<void>? hold;

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (method == 'prompt.submit') {
      submits.add(params['text'] as String);
      await hold?.future;
      return {'status': 'queued'};
    }
    return {};
  }

  @override
  RemoteFilesClient createFilesClient({
    String? sessionId,
    int? maxDownloadBytes,
  }) => _WidgetFiles(
    '<p>Widget</p><button data-hermes-send="run report">Go</button>',
  );
}

Future<void> _pumpNg(
  WidgetTester tester,
  SharedPreferences prefs,
  NextGenGateway gateway,
  NgChatController chat,
) async {
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

Widget _classicApp(Widget child) => MaterialApp(
  theme: hermesTheme(Brightness.light),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

List<String> _captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

const _partialDash =
    'Here it is:\n\n```html\n<!doctype html><html><head>'
    '<title>Dash</title></head><body><p>Part one';
const _finalDash =
    'Here it is:\n\n```html\n<!doctype html><html><head>'
    '<title>Dash</title></head><body><p>Part one</p>'
    '<p>FINAL PART</p></body></html>\n```\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(mockChatImageRecovery);
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
    HermesSignInVault.resetForTesting(MemorySignInSecretStore());
    resetSandboxedRenderer();
  });
  tearDown(resetSandboxedRenderer);

  group('B1 agent text cannot stall the UI thread', () {
    test('an html fence of "<a " x5000 is read within a frame', () {
      final input = '<a ' * 5000;
      final ms = _coldMs(
        () => detectArtifact('html', '<a href="x">y</a>'),
        () => detectArtifact('html', input),
      );
      expect(ms, lessThan(_frameBudgetMs), reason: '_htmlTag ${ms}ms');
      expect(detectArtifact('html', input), isNull);
    });

    test('a document with <title> x5000 is read within a frame', () {
      final input = '<!doctype html>${'<title>' * 5000}';
      final ms = _coldMs(
        () => detectArtifact('html', '<!doctype html><title>t</title>'),
        () => detectArtifact('html', input),
      );
      expect(ms, lessThan(_frameBudgetMs), reason: '_titleFromTag ${ms}ms');
      expect(detectArtifact('html', input)?.title, 'HTML');
    });

    test(
      'a Mermaid line of A, 10 KB of spaces and B parses within a frame',
      () {
        final input = 'flowchart TD\nA${' ' * 10000}B';
        final ms = _coldMs(
          () => parseMermaid('flowchart TD\nA --> B'),
          () => parseMermaid(input),
        );
        expect(ms, lessThan(_frameBudgetMs), reason: 'Mermaid link ${ms}ms');
      },
    );

    test('a reply of 5000 quote lines splits within a frame', () {
      final input = '\n> ' * 5000;
      final ms = _coldMs(
        () => splitRichProse('> [!NOTE]\n> x'),
        () => splitRichProse(input),
      );
      expect(ms, lessThan(_frameBudgetMs), reason: 'alert scan ${ms}ms');
    });

    test('unchanged text is not scanned again on the next rebuild', () {
      const doc =
          '<!doctype html><html><head><title>Dash</title></head>'
          '<body><p>x</p></body></html>';
      expect(
        identical(detectArtifact('html', doc), detectArtifact('html', doc)),
        isTrue,
      );
      const corpus = '```html\n$doc\n```\n';
      expect(
        identical(
          artifactHistoryFromText(corpus),
          artifactHistoryFromText(corpus),
        ),
        isTrue,
      );
      const diagram = 'flowchart TD\n  Start[Begin] --> EndNode[Finish]';
      expect(identical(parseMermaid(diagram), parseMermaid(diagram)), isTrue);
      const prose = '> [!TIP]\n> Keep going\n\nDone.';
      expect(identical(splitRichProse(prose), splitRichProse(prose)), isTrue);
    });

    test('the linear scans keep what the patterns found', () {
      expect(
        detectArtifact(
          'html',
          '<!DOCTYPE HTML><HTML><HEAD><TITLE>Big <b>Dash</b></TITLE></HEAD>',
        )?.title,
        'Big Dash',
      );
      expect(
        detectArtifact(
          'html',
          '<body>\n<h1 class="x">Report</h1></body>',
        )?.title,
        'Report',
      );
      expect(detectArtifact('html', '<p>short</p>'), isNull);
      final fragment = '<section class="a">${'word ' * 300}</section>';
      expect(
        detectArtifact('html', fragment)?.kind,
        GeneratedArtifactKind.html,
      );
      expect(detectArtifact('html', 'x' * 1300), isNull);

      final flow = parseMermaid(
        'graph LR\n  A[Start] -->|yes| B{Check]\n  B --- C(Done)\n  D',
      )!;
      expect(flow.direction, 'LR');
      expect(flow.nodes.map((node) => node.id), ['A', 'B', 'C', 'D']);
      expect(
        flow.edges.map((edge) => '${edge.from}>${edge.to}:${edge.label}'),
        ['A>B:yes', 'B>C:null'],
      );
      expect(parseMermaid('flowchart TD\n  A ---> B'), isNull);

      final alert = splitRichProse(
        'Intro\n> [!WARNING]\n> Mind the gap\n> twice\n\nAfter',
      );
      final pieces = alert.whereType<RichPiece>().toList();
      expect(pieces, hasLength(1));
      final piece = pieces.single.value as AlertPiece;
      expect(piece.type, 'warning');
      expect(piece.body, 'Mind the gap\ntwice');
    });
  });

  group('B2 artefact cards settle on the finished reply', () {
    testWidgets('R3 NextGen copies and renders the final part', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final copied = _captureClipboard(tester);
      final gateway = NextGenGateway(_connection('c1'));
      final chat = NgChatController(gateway, sessionId: 's')..runtimeId = 'rt';
      chat.debugApplyHistory([
        {'role': 'user', 'content': 'Build a page'},
        {'role': 'assistant', 'content': 'placeholder'},
      ]);
      addTearDown(() {
        chat.dispose();
        gateway.dispose();
      });
      final reply = chat.items.whereType<NgAssistantItem>().last;
      reply
        ..open = true
        ..text = _partialDash;
      await _pumpNg(tester, prefs, gateway, chat);
      expect(find.text('Dash'), findsWidgets);

      reply
        ..text = _finalDash
        ..open = false;
      await _pumpNg(tester, prefs, gateway, chat);
      final copy = find.textContaining('Copy Dash');
      await tester.ensureVisible(copy.first);
      await tester.tap(copy.first);
      await tester.pump();
      expect(find.textContaining('FINAL PART'), findsWidgets);
      expect(copied.single, contains('FINAL PART'));
      await tester.pumpWidget(const SizedBox());
    });

    // Classic draws a fence once it closes, so its stale copy shows when the
    // shown reply is replaced (the streamed text by the stored reply) and
    // when a later revision of the same artefact arrives in the reply.
    testWidgets('Classic copies and renders the final part', (tester) async {
      final copied = _captureClipboard(tester);
      await tester.pumpWidget(
        _classicApp(
          const MessageBubble(content: '$_partialDash\n```\n', isUser: false),
        ),
      );
      expect(find.text('Dash'), findsWidgets);
      await tester.pumpWidget(
        _classicApp(const MessageBubble(content: _finalDash, isUser: false)),
      );
      final copy = find.textContaining('Copy Dash');
      await tester.ensureVisible(copy.first);
      await tester.tap(copy.first);
      await tester.pump();
      expect(find.textContaining('FINAL PART'), findsWidgets);
      expect(copied.single, contains('FINAL PART'));
    });

    testWidgets('Classic revision counts follow a growing reply', (
      tester,
    ) async {
      const first = '$_partialDash</p></body></html>\n```\n';
      await tester.pumpWidget(
        _classicApp(const MessageBubble(content: first, isUser: false)),
      );
      expect(find.text('Revision 1 of 1'), findsOneWidget);
      await tester.pumpWidget(
        _classicApp(
          const MessageBubble(
            content: '$first\nRevised:\n\n$_finalDash',
            isUser: false,
          ),
        ),
      );
      expect(find.text('Revision 1 of 2'), findsOneWidget);
      expect(find.text('Revision 2 of 2'), findsOneWidget);
    });
  });

  group('B3 one widget intent per second, none while one is in flight', () {
    testWidgets('R2 a rapid second tap does not send a second prompt', (
      tester,
    ) async {
      final sent = <String>[];
      final gate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxPreviewCard(
              file: 'w.html',
              readHtml: (_) async => WidgetHtmlSource(
                '<p>Widget</p><button data-hermes-send="run report">Go</button>',
              ),
              onIntent: (prompt) async {
                sent.add(prompt);
                await gate.future;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Go'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Go'));
      await tester.pump(const Duration(milliseconds: 100));
      gate.complete();
      await tester.pump();
      expect(sent, ['run report']);
    });

    testWidgets('R2 Classic reply widget delivers one prompt', (tester) async {
      final sent = <String>[];
      final gate = Completer<void>();
      await tester.pumpWidget(
        _classicApp(
          MessageBubble(
            content: 'Widget:\n\n::preview{file="w.html"}\n',
            isUser: false,
            readWidgetHtml: (_) async => WidgetHtmlSource(
              '<p>Widget</p><button data-hermes-send="run report">Go</button>',
            ),
            onWidgetIntent: (prompt) async {
              sent.add(prompt);
              await gate.future;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Go'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Go'));
      await tester.pump(const Duration(milliseconds: 100));
      gate.complete();
      await tester.pump();
      expect(sent, ['run report']);
    });

    testWidgets('R2 NextGen reply widget submits one hidden prompt', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      final gateway = _IntentGateway();
      final chat = NgChatController(gateway, sessionId: 's')..runtimeId = 'rt';
      chat.debugApplyHistory([
        {'role': 'user', 'content': 'Show the widget'},
        {
          'role': 'assistant',
          'content': 'Widget:\n\n::preview{file="w.html"}\n',
        },
      ]);
      addTearDown(() {
        chat.dispose();
        gateway.dispose();
      });
      await _pumpNg(tester, prefs, gateway, chat);
      await tester.pump();
      await tester.pump();
      final hold = gateway.hold = Completer<void>();
      await tester.tap(find.text('Go'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Go'));
      await tester.pump(const Duration(milliseconds: 100));
      hold.complete();
      await tester.pump();
      expect(gateway.submits, ['run report']);
      expect(find.text('run report'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('NextGen refuses a widget intent while a turn is running', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      final gateway = _IntentGateway();
      final chat = NgChatController(gateway, sessionId: 's')..runtimeId = 'rt';
      chat.debugApplyHistory([
        {'role': 'user', 'content': 'Show the widget'},
        {
          'role': 'assistant',
          'content': 'Widget:\n\n::preview{file="w.html"}\n',
        },
      ]);
      addTearDown(() {
        chat.dispose();
        gateway.dispose();
      });
      await _pumpNg(tester, prefs, gateway, chat);
      await tester.pump();
      await tester.pump();
      gateway.debugEmit(
        StreamEvent(type: 'message.start', data: const {}, sessionId: 'rt'),
      );
      await tester.pump();
      expect(chat.running, isTrue);
      await tester.ensureVisible(find.text('Go'));
      await tester.tap(find.text('Go'));
      await tester.pump();
      await tester.pump();
      expect(gateway.submits, isEmpty);
      // The refusal code `undelivered`, worded.
      expect(find.text('Not sent to this chat'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('B4 no fixture or unwired controls', () {
    testWidgets('Contributions offers no example origin or foreign install', (
      tester,
    ) async {
      final page = aresWorkspaceRegistry.page('extensions.contributions')!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => page.build(
              context,
              WorkspaceTarget(_connection('c1'), null, false, () => true),
            ),
          ),
        ),
      );
      expect(find.text('Grant Notes'), findsOneWidget);
      expect(find.textContaining('example.test'), findsNothing);
      expect(find.textContaining('remote.example'), findsNothing);
      expect(find.text('Allow this site'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('Classic setup and install tool rows add no stub buttons', (
      tester,
    ) async {
      await tester.pumpWidget(
        _classicApp(
          GatewayActivityCard(
            pinnedExpansion: true,
            activities: [
              GatewayToolActivity(
                name: 'setup_beat',
                phase: GatewayToolActivityPhase.completed,
                detail: '{"beat":"name"}',
              ),
              GatewayToolActivity(
                name: 'catalog_install',
                phase: GatewayToolActivityPhase.completed,
                detail: '{"id":"notes"}',
              ),
            ],
          ),
        ),
      );
      expect(find.text('Name the agent'), findsNothing);
      expect(find.text('Keep the default'), findsNothing);
      expect(find.text('Install notes'), findsNothing);
      expect(find.text('Install remote.example'), findsNothing);
    });

    testWidgets('NextGen setup tool row adds no stub buttons', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final gateway = NextGenGateway(_connection('c1'));
      final chat = NgChatController(gateway, sessionId: 's')..runtimeId = 'rt';
      chat.debugApplyHistory([
        {'role': 'user', 'content': 'Set me up'},
        {
          'role': 'assistant',
          'content': '',
          'id': 'a1',
          'tool_calls': [
            {
              'id': 't-1',
              'function': {
                'name': 'setup_beat',
                'arguments': '{"beat":"name"}',
              },
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 't-1', 'content': '{"name":"Ada"}'},
      ]);
      addTearDown(() {
        chat.dispose();
        gateway.dispose();
      });
      await _pumpNg(tester, prefs, gateway, chat);
      await tester.tap(find.text('Used setup_beat'));
      await tester.pump();
      await tester.tap(find.text('setup_beat'));
      await tester.pump();
      expect(find.text('Name the agent'), findsNothing);
      expect(find.text('Keep the default'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'audio seek stays disabled until real native metadata is available',
      (tester) async {
        await tester.pumpWidget(
          _classicApp(
            MediaArtifactCard(
              ref: MediaTagRef(path: '/tmp/talk.mp3'),
              filesClient: () => _WidgetFiles(''),
            ),
          ),
        );
        expect(find.byType(Slider), findsOneWidget);
        expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
        expect(find.byTooltip('Play'), findsOneWidget);
        expect(find.text('1.5x'), findsNothing);
        expect(find.text('Playback in this transcript'), findsNothing);
      },
    );

    testWidgets('NextGen offers no dead preview suggestion chips', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      final gateway = NextGenGateway(_connection('c1'));
      final chat = NgChatController(gateway, sessionId: 's')..runtimeId = 'rt';
      chat.debugApplyHistory([
        {'role': 'user', 'content': 'Start it'},
        {'role': 'assistant', 'content': 'Running at http://localhost:3000/'},
      ]);
      addTearDown(() {
        chat.dispose();
        gateway.dispose();
      });
      await _pumpNg(tester, prefs, gateway, chat);
      await tester.pump();
      expect(
        find.byKey(const Key('preview-suggestion-http://localhost:3000/')),
        findsNothing,
      );
      expect(find.byType(InputChip), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('B5 chat choices stay in their chat', () {
    // Embed consent per chat was removed with the consent card itself
    // (render_recheck_blockers_test.dart R2): provider URLs are plain links.
    testWidgets('a contribution granted for one connection is not another', (
      tester,
    ) async {
      final page = aresWorkspaceRegistry.page('extensions.contributions')!;
      Widget open(String id) => MaterialApp(
        key: ValueKey(id),
        home: Builder(
          builder: (context) => page.build(
            context,
            WorkspaceTarget(_connection(id), null, false, () => true),
          ),
        ),
      );
      await tester.pumpWidget(open('c1'));
      await tester.tap(find.text('Grant Notes'));
      await tester.pump();
      expect(find.text('Revoke Notes'), findsOneWidget);
      await tester.pumpWidget(open('c2'));
      expect(find.text('Grant Notes'), findsOneWidget);
      expect(find.text('Revoke Notes'), findsNothing);
    });
  });
}
