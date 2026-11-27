// Item 4 of the 6c6508ea re-check: the rich renderer, the Contributions page
// and the catalog card read their words from the ARB files, translated in
// every shipped locale, in both layouts. Classic trees carry the generated
// delegate; NextGen trees do not, so the shared widgets fall back to the
// ambient locale (context.sharedL10n). Both are pumped here in German.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/render/catalog_install.dart';
import 'package:hermes_android/core/render/contributions_page.dart';
import 'package:hermes_android/core/render/rich_blocks.dart';
import 'package:hermes_android/core/render/rich_transcript.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _keys = [
  'render_svg_not_drawn',
  'render_notes_directive',
  'render_maths_source',
  'render_inline_maths_source',
  'render_sequence_outline',
  'render_diagram_outline',
  'render_revision_of',
  'render_previous_revision',
  'render_next_revision',
  'render_show_rendered',
  'render_show_source',
  'render_copied_file',
  'render_copy_file',
  'render_artifact_too_long',
  'render_active_content_removed',
  'render_widget_file',
  'render_widget_runs_as_text',
  'render_load_widget',
  'render_not_html_widget',
  'render_widget_sent',
  'render_widget_not_sent',
  'render_widget_throttled',
  'render_widget_too_long',
  'render_widget_no_gesture',
  'render_widget_invalid',
  'render_inspected_image',
  'render_contributions',
  'render_contributions_intro',
  'render_grant_plugin',
  'render_revoke_plugin',
  'render_plugin_slots',
  'render_plugin_notes',
  'catalog_scan_passed',
  'catalog_scan_warnings',
  'catalog_scan_failed',
];

/// Words a locale writes as English does.
const _sameAsEnglish = {
  'fr': {'render_contributions', 'render_plugin_notes'},
};

Widget _classic(Widget child) => MaterialApp(
  locale: const Locale('de'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Widget _nextGen(Widget child) => MaterialApp(
  locale: const Locale('de'),
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

const _page =
    '<!doctype html><html><head><title>Board</title></head><body>'
    '<p>ALPHA</p><script>alert(1)</script></body></html>';

void main() {
  test('every render string is translated in every locale', () {
    final dir = Directory('lib/l10n');
    final en =
        jsonDecode(File('${dir.path}/app_en.arb').readAsStringSync())
            as Map<String, dynamic>;
    final placeholder = RegExp(r'\{(\w+)\}');
    Set<String?> names(String text) =>
        placeholder.allMatches(text).map((m) => m[1]).toSet();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.arb'))
        .toList();
    expect(files, hasLength(greaterThanOrEqualTo(12)));
    for (final file in files) {
      final locale = file.uri.pathSegments.last
          .replaceFirst('app_', '')
          .replaceFirst('.arb', '');
      final arb = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final key in _keys) {
        expect(arb[key], isA<String>(), reason: '$locale $key');
        expect(names(arb[key] as String), names(en[key] as String));
        if (locale == 'en' ||
            (_sameAsEnglish[locale]?.contains(key) ?? false)) {
          continue;
        }
        expect(arb[key], isNot(en[key]), reason: '$locale $key is English');
      }
    }
  });

  for (final (layout, app) in [('Classic', _classic), ('NextGen', _nextGen)]) {
    group(layout, () {
      testWidgets('an artefact card speaks German', (tester) async {
        await tester.pumpWidget(
          app(
            RichFence(
              language: 'html',
              code: _page,
              corpus: '```html\n$_page\n```\n',
              fallback: const Text('fallback'),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Revision 1 von 1'), findsOneWidget);
        expect(find.text('Vorherige Revision'), findsOneWidget);
        expect(find.text('Nächste Revision'), findsOneWidget);
        expect(find.text('Board.html kopieren'), findsOneWidget);
        expect(
          find.text('Skripte, Frames und externe Adressen wurden entfernt.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Quelltext'));
        await tester.pump();
        expect(find.text('Dargestellt'), findsOneWidget);
      });

      testWidgets('maths, diagrams, SVG and inspected images speak German', (
        tester,
      ) async {
        await tester.pumpWidget(
          app(
            Column(
              children: [
                const MathBlock(piece: MathPiece('x^2', display: true)),
                const MathBlock(piece: MathPiece('y', display: false)),
                DiagramView(model: parseMermaid('flowchart TD\nA --> B')!),
                DiagramView(
                  model: parseMermaid('sequenceDiagram\nAlice->>Bob: Hello')!,
                ),
                const RichFence(
                  language: 'svg',
                  code: '<svg><g',
                  corpus: '',
                  fallback: Text('fallback'),
                ),
                const InspectedImageTile(source: 'Looked at /tmp/shot.png'),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Formelquelle'), findsOneWidget);
        expect(find.text('Inline-Formelquelle'), findsOneWidget);
        expect(find.text('Diagrammübersicht'), findsOneWidget);
        expect(find.text('Ablaufübersicht'), findsOneWidget);
        expect(find.text('Dieses SVG wurde nicht gezeichnet.'), findsOneWidget);
        expect(find.text('Untersuchtes Bild'), findsOneWidget);
      });

      testWidgets('a widget card speaks German', (tester) async {
        final sent = <String>[];
        await tester.pumpWidget(
          app(
            Column(
              children: [
                SandboxPreviewCard(
                  file: 'w.html',
                  readHtml: (_) async => const WidgetHtmlSource(
                    '<p>Body</p><button data-hermes-send="run">Go</button>',
                  ),
                  onIntent: (prompt) async => sent.add(prompt),
                ),
                SandboxPreviewCard(
                  file: 'notes.txt',
                  readHtml: (_) async => null,
                ),
                SandboxPreviewCard(
                  file: 'gone.html',
                  readHtml: (_) async => null,
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('Widget-Datei w.html'), findsOneWidget);
        expect(
          find.text(
            'Läuft als Text in diesem Chat. Skripte und externe Frames '
            'werden entfernt.',
          ),
          findsNWidgets(3),
        );
        expect(find.text('Diese Datei ist kein HTML-Widget.'), findsOneWidget);
        expect(
          find.text(
            'Diese Datei konnte nicht geladen werden. Verbindung prüfen und '
            'erneut versuchen.',
          ),
          findsOneWidget,
        );
        expect(find.text('Widget laden'), findsOneWidget);
        await tester.tap(find.text('Go'));
        await tester.pump();
        expect(sent, ['run']);
        expect(find.text('An diesen Chat gesendet'), findsOneWidget);
        await tester.tap(find.text('Go'));
        await tester.pump();
        expect(sent, ['run']);
        expect(
          find.text('Warte kurz, bevor du erneut sendest'),
          findsOneWidget,
        );
      });

      testWidgets('the catalog card words the scan and platforms', (
        tester,
      ) async {
        final operation = CatalogOperation.parse({
          'op_id': 'op-1',
          'seq': 1,
          'targets': [
            {
              'name': 'blender',
              'kind': 'plugin',
              'state': 'pending',
              'display': 'Blender',
              'platforms': ['darwin', 'linux'],
              'scan': {'status': 'passed', 'summary': 'Keine Funde'},
            },
          ],
        })!;
        await tester.pumpWidget(
          app(
            CatalogInstallCard(
              operation: operation,
              respond: (_) async => true,
            ),
          ),
        );
        await tester.pump();
        expect(
          find.text('Sicherheitsprüfung: bestanden. Keine Funde'),
          findsOneWidget,
        );
        expect(find.text('macOS'), findsOneWidget);
        expect(find.text('Linux'), findsOneWidget);
      });
    });
  }

  for (final (layout, delegates) in [
    ('Classic', AppLocalizations.localizationsDelegates),
    (
      'NextGen',
      const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    ),
  ]) {
    testWidgets('$layout Contributions page speaks German', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('de'),
          localizationsDelegates: delegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ContributionsPage(scope: 'c1\u0000'),
        ),
      );
      expect(find.text('Beiträge'), findsOneWidget);
      expect(
        find.text(
          'Nur in Ares eingebaute Beiträge können eine Antwort ergänzen. '
          'Chattext kann keinen registrieren, und eine Freigabe gilt nur für '
          'diese Verbindung.',
        ),
        findsOneWidget,
      );
      expect(find.text('Notizen'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('plugin-slots-notes'))).data,
        'Antwortkarten für ::notes',
      );
      await tester.tap(find.text('Notizen erlauben'));
      await tester.pump();
      expect(find.text('Notizen entziehen'), findsOneWidget);
      await tester.tap(find.text('Notizen entziehen'));
      await tester.pump();
    });
  }
}
