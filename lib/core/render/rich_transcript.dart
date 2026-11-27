import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../l10n/l10n.dart';
import 'artifact_library.dart';
import 'plugin_slots.dart';
import 'render_contract.dart';
import 'render_scope.dart';
import 'rich_blocks.dart';

/// An HTML widget file as the gateway returned it.
class WidgetHtmlSource {
  const WidgetHtmlSource(this.text, {this.truncated = false});

  final String text;

  /// The gateway sent only the start of the file (its read limit).
  final bool truncated;
}

/// Reads a `::preview{file=…}` widget file for the chat that shows it.
typedef WidgetHtmlReader = Future<WidgetHtmlSource?> Function(String path);

bool richProseContainsTable(String text) => splitRichProse(
  text,
).any((piece) => piece is RichPiece && piece.value is TablePiece);

List<Widget> richProseWidgets({
  required String text,
  required Widget Function(String text) markdown,
  bool tablesOnly = false,
  WidgetHtmlReader? readHtml,
  Future<void> Function(String prompt)? onIntent,
}) {
  final pieces = tablesOnly ? splitTableProse(text) : splitRichProse(text);
  if (pieces.length == 1 && pieces.single is ProsePiece) {
    return [markdown(text)];
  }
  final widgets = <Widget>[];
  for (final piece in pieces) {
    if (piece is ProsePiece) {
      if (piece.text.trim().isEmpty) continue;
      widgets.add(markdown(piece.text));
    } else if (piece is RichPiece) {
      widgets.add(
        RichPieceView(
          value: piece.value,
          markdown: markdown,
          readHtml: readHtml,
          onIntent: onIntent,
        ),
      );
    }
  }
  if (widgets.isEmpty) return [markdown(text)];
  return widgets;
}

class RichFence extends StatelessWidget {
  const RichFence({
    super.key,
    required this.language,
    required this.code,
    required this.corpus,
    required this.fallback,
    this.readHtml,
    this.onIntent,
  });

  final String? language;
  final String code;
  final String corpus;
  final Widget fallback;
  final WidgetHtmlReader? readHtml;
  final Future<void> Function(String prompt)? onIntent;

  @override
  Widget build(BuildContext context) {
    final clean = sanitizeLanguageTag(language);
    final detection = detectArtifact(language, code);
    if (detection != null) {
      return ArtifactRevisionCard(
        corpus: corpus,
        code: code,
        detection: detection,
        fallback: fallback,
      );
    }
    if (clean == 'mermaid') {
      final model = parseMermaid(code);
      if (model != null) return DiagramView(model: model);
    }
    if (clean == 'svg') {
      final drawing = code.length > artifactRenderChars
          ? null
          : _drawings.lookup(code, () => parseSafeSvg(code));
      if (drawing != null) return SafeSvgView(drawing: drawing);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [Text(context.sharedL10n.render_svg_not_drawn), fallback],
      );
    }
    if (clean == 'listing') {
      final cards = parseListings(code);
      if (cards.isNotEmpty) return ListingSet(cards: cards);
    }
    return fallback;
  }
}

class RichPieceView extends StatelessWidget {
  const RichPieceView({
    super.key,
    required this.value,
    required this.markdown,
    this.readHtml,
    this.onIntent,
  });

  final Object value;
  final Widget Function(String text) markdown;
  final WidgetHtmlReader? readHtml;
  final Future<void> Function(String prompt)? onIntent;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    if (value is AlertPiece) return AlertBanner(alert: value);
    if (value is MathPiece) return MathBlock(piece: value);
    if (value is TablePiece) {
      return ResizableMarkdownTable(table: value, markdown: markdown);
    }
    if (value is DirectivePiece) {
      if (value.name == 'preview') {
        return SandboxPreviewCard(
          file: value.attrs['file'] ?? '',
          readHtml: readHtml,
          onIntent: onIntent,
        );
      }
      final scope = RenderScope.maybeOf(context)?.connection;
      return ListenableBuilder(
        listenable: pluginGrants,
        builder: (context, _) {
          if (scope == null ||
              !pluginGrants.showsDirective(scope, value.name)) {
            return Text(value.raw);
          }
          return _GrantedDirective(directive: value);
        },
      );
    }
    return const SizedBox.shrink();
  }
}

class _GrantedDirective extends StatelessWidget {
  const _GrantedDirective({required this.directive});

  final DirectivePiece directive;

  @override
  Widget build(BuildContext context) {
    final text = directive.attrs['text'] ?? directive.attrs.values.join(' ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.sharedL10n.render_notes_directive),
            Text(text),
          ],
        ),
      ),
    );
  }
}

class AlertBanner extends StatelessWidget {
  const AlertBanner({super.key, required this.alert});

  final AlertPiece alert;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = context.sharedL10n;
    final label = switch (alert.type) {
      'note' => l.release_preview_note,
      'tip' => l.rel_svc_misc_alert_tip,
      'important' => l.rel_svc_misc_alert_important,
      'warning' => l.rel_svc_misc_alert_warning,
      'caution' => l.rel_svc_misc_alert_caution,
      _ => alert.type,
    };
    return Container(
      key: Key('alert-${alert.type}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
        color: scheme.surfaceContainerHighest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(alert.body),
        ],
      ),
    );
  }
}

class MathBlock extends StatelessWidget {
  const MathBlock({super.key, required this.piece});

  final MathPiece piece;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: piece.display
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          // The expression is shown as written; it is not typeset.
          Text(
            piece.display
                ? context.sharedL10n.render_maths_source
                : context.sharedL10n.render_inline_maths_source,
          ),
          Text(piece.source, key: const Key('math-expression')),
        ],
      ),
    );
  }
}

/// A bounded-width grid: measure no cell intrinsically. Sample only a few
/// source lengths to budget columns, then let Table align multiline row heights.
class ResizableMarkdownTable extends StatefulWidget {
  const ResizableMarkdownTable({super.key, required this.table, this.markdown});

  final TablePiece table;

  /// Reuse the caller's inline Markdown styles, link routing and selection area.
  final Widget Function(String text)? markdown;

  @override
  State<ResizableMarkdownTable> createState() => _ResizableMarkdownTableState();
}

class _ResizableMarkdownTableState extends State<ResizableMarkdownTable> {
  final _scroll = ScrollController();
  final _resized = <int, double>{};

  @override
  void didUpdateWidget(ResizableMarkdownTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.table.headers, widget.table.headers)) {
      _resized.clear();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final headers = widget.table.headers;
    if (headers.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, box) {
        // Parent is the chat pane, never the physical screen (split views too).
        final available = box.hasBoundedWidth ? box.maxWidth : 640.0;
        final widths = <double>[];
        for (var i = 0; i < headers.length; i++) {
          var longest = headers[i].length;
          for (final row in widget.table.rows.take(12)) {
            if (i < row.length && row[i].length > longest) {
              longest = row[i].length;
            }
          }
          widths.add(_resized[i] ?? ((longest > 40 ? 240.0 : 160.0) * scale));
        }
        final natural = widths.fold<double>(0, (sum, width) => sum + width);
        if (natural < available) {
          final extra = (available - natural) / headers.length;
          for (var i = 0; i < widths.length; i++) {
            widths[i] += extra;
          }
        }
        final total = widths.fold<double>(0, (sum, width) => sum + width);
        final overflow = total > available + 0.5;
        return SizedBox(
          width: available,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Scrollbar(
                controller: _scroll,
                thumbVisibility: overflow,
                trackVisibility: overflow,
                notificationPredicate: (notification) =>
                    notification.depth == 0,
                child: SingleChildScrollView(
                  key: const Key('table-horizontal-scroll'),
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.only(bottom: overflow ? 14 : 0),
                  child: SizedBox(
                    width: total,
                    child: Table(
                      key: const Key('markdown-table-grid'),
                      border: TableBorder.all(color: scheme.outline),
                      defaultVerticalAlignment: TableCellVerticalAlignment.top,
                      columnWidths: {
                        for (var i = 0; i < widths.length; i++)
                          i: FixedColumnWidth(widths[i]),
                      },
                      children: [
                        TableRow(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                          ),
                          children: [
                            for (var i = 0; i < headers.length; i++)
                              _cell(
                                i,
                                headers[i],
                                widths[i],
                                scale,
                                header: true,
                              ),
                          ],
                        ),
                        for (final row in widget.table.rows)
                          TableRow(
                            children: [
                              for (var i = 0; i < headers.length; i++)
                                _cell(
                                  i,
                                  i < row.length ? row[i] : '',
                                  widths[i],
                                  scale,
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (overflow)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Icon(
                    Icons.swap_horiz,
                    key: const Key('table-overflow-hint'),
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _cell(
    int index,
    String text,
    double width,
    double scale, {
    bool header = false,
  }) {
    final body =
        widget.markdown?.call(header ? '**$text**' : text) ??
        MarkdownBody(data: header ? '**$text**' : text, selectable: false);
    return Stack(
      key: header ? Key('table-col-$index') : null,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: body,
        ),
        if (header && index < widget.table.headers.length - 1)
          PositionedDirectional(
            end: 0,
            top: 0,
            bottom: 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                key: Key('table-resize-$index'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) {
                  final sign = Directionality.of(context) == TextDirection.rtl
                      ? -1
                      : 1;
                  setState(() {
                    _resized[index] = (width + details.delta.dx * sign).clamp(
                      144 * scale,
                      640 * scale,
                    );
                  });
                },
                child: const SizedBox(width: 12),
              ),
            ),
          ),
      ],
    );
  }
}

class DiagramView extends StatelessWidget {
  const DiagramView({super.key, required this.model});

  final DiagramModel model;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Nodes and links as text; the diagram itself is not drawn.
          Text(
            model.kind == 'sequence'
                ? context.sharedL10n.render_sequence_outline
                : context.sharedL10n.render_diagram_outline,
          ),
          for (final node in model.nodes)
            Text(node.label, key: Key('diagram-${node.id}')),
          for (final edge in model.edges)
            Text(
              '${edge.from} → ${edge.to}${edge.label == null ? '' : ' ${edge.label}'}',
            ),
        ],
      ),
    );
  }
}

class SafeSvgView extends StatelessWidget {
  const SafeSvgView({super.key, required this.drawing});

  final SvgDrawing drawing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      width: double.infinity,
      child: CustomPaint(
        painter: _SvgPainter(drawing, Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _SvgPainter extends CustomPainter {
  _SvgPainter(this.drawing, this.color);

  final SvgDrawing drawing;
  final Color color;

  double? _n(String? value) => value == null ? null : double.tryParse(value);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final op in drawing.ops) {
      final attrs = op.attrs;
      switch (op.name) {
        case 'rect':
          final rect = Rect.fromLTWH(
            _n(attrs['x']) ?? 0,
            _n(attrs['y']) ?? 0,
            _n(attrs['width']) ?? 0,
            _n(attrs['height']) ?? 0,
          );
          canvas.drawRect(rect, paint);
        case 'circle':
          canvas.drawCircle(
            Offset(_n(attrs['cx']) ?? 0, _n(attrs['cy']) ?? 0),
            _n(attrs['r']) ?? 0,
            paint,
          );
        case 'line':
          canvas.drawLine(
            Offset(_n(attrs['x1']) ?? 0, _n(attrs['y1']) ?? 0),
            Offset(_n(attrs['x2']) ?? 0, _n(attrs['y2']) ?? 0),
            paint,
          );
        case 'text':
          final painter = TextPainter(
            text: TextSpan(
              text: attrs['text'] ?? '',
              style: TextStyle(color: color, fontSize: 12),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          painter.paint(
            canvas,
            Offset(_n(attrs['x']) ?? 0, _n(attrs['y']) ?? 0),
          );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SvgPainter oldDelegate) =>
      oldDelegate.drawing != drawing || oldDelegate.color != color;
}

class ListingSet extends StatelessWidget {
  const ListingSet({super.key, required this.cards});

  final List<ListingCard> cards;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final card in cards)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(card.address),
                  if (card.price != null) Text(card.price!),
                  if (card.note != null) Text(card.note!),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class ArtifactRevisionCard extends StatefulWidget {
  const ArtifactRevisionCard({
    super.key,
    required this.corpus,
    required this.code,
    required this.detection,
    required this.fallback,
  });

  final String corpus;
  final String code;
  final GeneratedArtifact detection;
  final Widget fallback;

  @override
  State<ArtifactRevisionCard> createState() => _ArtifactRevisionCardState();
}

/// A revision bigger than this shows its source instead of a parsed page,
/// so one long artefact cannot stall every streamed token.
const artifactRenderChars = 32 * 1024;

/// HTML up to this size is parsed inline. A longer page is parsed on a
/// background isolate and cached by content, so a page that is still
/// streaming is not parsed again on the UI thread for every token.
const sandboxInlineParseChars = 8 * 1024;

final _pages = ContentMemo<SandboxDocument?>(16);
final _pageParses = <String, Future<SandboxDocument?>>{};
final _drawings = ContentMemo<SvgDrawing?>(16);

/// Pages parsed on the UI thread and on a background isolate, for tests.
@visibleForTesting
int debugInlinePageParses = 0;
@visibleForTesting
int debugBackgroundPageParses = 0;

/// The parsed page if it is ready: at once for a short page, from the cache
/// for a longer one. `ready` is false while a longer page has not been
/// parsed yet; [parseSandboxedPage] parses it.
({SandboxDocument? document, bool ready}) readSandboxedPage(String content) {
  if (content.length <= sandboxInlineParseChars) {
    final document = _pages.lookup(content, () {
      debugInlinePageParses++;
      return parseSandboxedHtml(content);
    });
    return (document: document, ready: true);
  }
  final hit = _pages.peek(content);
  return (document: hit?.value, ready: hit != null);
}

SandboxDocument? _parseInBackground(String content) =>
    parseSandboxedHtml(content);

/// Parses [content] (off the UI thread when it is long) and caches it. One
/// parse runs per content at a time.
Future<SandboxDocument?> parseSandboxedPage(String content) {
  final ready = readSandboxedPage(content);
  if (ready.ready) return Future.value(ready.document);
  final key = '${artifactContentHash(content)}:${content.length}';
  return _pageParses.putIfAbsent(key, () {
    debugBackgroundPageParses++;
    return compute(_parseInBackground, content)
        .then<SandboxDocument?>((document) {
          _pages.put(content, document);
          return document;
        }, onError: (Object _) => null)
        // A block body: returning the removed (this very) future from the
        // callback would make whenComplete wait for itself.
        .whenComplete(() {
          _pageParses.remove(key);
        });
  });
}

/// Drops parsed pages and drawings, for a renderer reset.
void resetSandboxedPages() {
  _pages.clear();
  _pageParses.clear();
  _drawings.clear();
  debugInlinePageParses = 0;
  debugBackgroundPageParses = 0;
}

/// Revisions follow the reply as it streams: each rebuild with new text
/// re-reads the (memoised) history, so the card, Copy and download settle on
/// the final content. A revision the user stepped to stays selected.
class _ArtifactRevisionCardState extends State<ArtifactRevisionCard> {
  late List<ArtifactRevision> _revisions;
  late int _index;
  String? _pinned;
  var _source = false;

  /// The last page this card drew for revision [_pageRevision]: a longer
  /// page that is still streaming keeps showing it while the next parse
  /// runs in the background, one parse at a time.
  SandboxDocument? _page;
  int? _pageRevision;
  var _parsing = false;

  SandboxDocument? _readPage(ArtifactRevision revision) {
    final page = readSandboxedPage(revision.content);
    if (page.ready) {
      _page = page.document;
      _pageRevision = revision.index;
      return page.document;
    }
    if (!_parsing) {
      _parsing = true;
      unawaited(
        parseSandboxedPage(revision.content).whenComplete(() {
          _parsing = false;
          if (mounted) setState(() {});
        }),
      );
    }
    return _pageRevision == revision.index ? _page : null;
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ArtifactRevisionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.corpus != widget.corpus ||
        oldWidget.code != widget.code ||
        artifactSlug(oldWidget.detection) != artifactSlug(widget.detection)) {
      _sync();
    }
  }

  String get _currentHash => artifactContentHash(widget.code.trim());

  void _sync() {
    _revisions = _load();
    final pinned = _pinned == null
        ? -1
        : _revisions.indexWhere((revision) => revision.hash == _pinned);
    if (pinned >= 0) {
      _index = pinned;
    } else {
      _pinned = null;
      _index = _initial();
    }
  }

  void _step(int delta) => setState(() {
    _index = (_index + delta).clamp(0, _revisions.length - 1);
    final hash = _revisions[_index].hash;
    _pinned = hash == _currentHash ? null : hash;
  });

  /// The stored revisions of this artefact, plus this fence as a
  /// provisional last revision when none of them is this fence's text (an
  /// open fence the history does not hold). Copy and download then use the
  /// card's own text, never the previous revision.
  List<ArtifactRevision> _load() {
    final slug = artifactSlug(widget.detection);
    final hash = _currentHash;
    var stored = const <ArtifactRevision>[];
    for (final artifact in artifactHistoryFromText(widget.corpus)) {
      if (artifact.slug == slug) {
        stored = artifact.revisions;
        break;
      }
    }
    if (stored.any((revision) => revision.hash == hash)) return stored;
    return [
      ...stored,
      ArtifactRevision(
        index: stored.length + 1,
        hash: hash,
        content: widget.code.trim(),
        detection: widget.detection,
      ),
    ];
  }

  int _initial() {
    final hash = _currentHash;
    final match = _revisions.indexWhere((revision) => revision.hash == hash);
    return match < 0 ? _revisions.length - 1 : match;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.sharedL10n;
    final revision = _revisions[_index];
    final content = revision.content;
    final tooLarge = content.length > artifactRenderChars;
    final html =
        !tooLarge && revision.detection.kind == GeneratedArtifactKind.html
        ? _readPage(revision)
        : null;
    final svg =
        !tooLarge && revision.detection.kind == GeneratedArtifactKind.svg
        ? _drawings.lookup(content, () => parseSafeSvg(content))
        : null;
    final source = revision.hash == _currentHash
        ? widget.fallback
        : SelectableText(
            content,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(revision.detection.title),
            Text(l.render_revision_of(revision.index, _revisions.length)),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _index == 0 ? null : () => _step(-1),
                  child: Text(l.render_previous_revision),
                ),
                TextButton(
                  onPressed: _index == _revisions.length - 1
                      ? null
                      : () => _step(1),
                  child: Text(l.render_next_revision),
                ),
                TextButton(
                  onPressed: () => setState(() => _source = !_source),
                  child: Text(
                    _source ? l.render_show_rendered : l.render_show_source,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: revision.content),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          l.render_copied_file(revision.downloadName),
                        ),
                      ),
                    );
                  },
                  child: Text(l.render_copy_file(revision.downloadName)),
                ),
              ],
            ),
            if (tooLarge && !_source) Text(l.render_artifact_too_long),
            if (_source || (html == null && svg == null))
              source
            else if (html != null)
              _HtmlBody(document: html)
            else if (svg != null)
              SafeSvgView(drawing: svg),
          ],
        ),
      ),
    );
  }
}

class _HtmlBody extends StatelessWidget {
  const _HtmlBody({required this.document});

  final SandboxDocument document;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (document.droppedActiveContent)
          Text(context.sharedL10n.render_active_content_removed),
        Text(document.text),
      ],
    );
  }
}

class SandboxPreviewCard extends StatefulWidget {
  const SandboxPreviewCard({
    super.key,
    required this.file,
    this.readHtml,
    this.onIntent,
  });

  final String file;
  final WidgetHtmlReader? readHtml;
  final Future<void> Function(String prompt)? onIntent;

  @override
  State<SandboxPreviewCard> createState() => _SandboxPreviewCardState();
}

class _SandboxPreviewCardState extends State<SandboxPreviewCard> {
  final _token = DateTime.now().microsecondsSinceEpoch.toString();
  SandboxDocument? _document;

  /// The read failed (connection, sign-in, missing file); a retry may work.
  var _failed = false;

  /// No reader, not an `.html` path, or the file holds no HTML.
  var _missing = false;
  var _truncated = false;

  /// Bumped by every load, so a slow read never lands on a newer one.
  var _generation = 0;

  /// [_sent], or the code an intent was refused with (`IntentRejected`:
  /// invalid, too_long, throttled, undelivered, no_gesture); worded while
  /// building, so the locale can change under it.
  String? _status;
  static const _sent = 'sent';
  var _lastAcceptedAt = 0;
  var _delivering = false;

  static String _statusText(AppLocalizations l, String status) =>
      switch (status) {
        _sent => l.render_widget_sent,
        'undelivered' => l.render_widget_not_sent,
        'throttled' => l.render_widget_throttled,
        'too_long' => l.render_widget_too_long,
        'no_gesture' => l.render_widget_no_gesture,
        _ => l.render_widget_invalid,
      };

  // The file is read as soon as the card shows, as the Desktop reads it
  // when the directive renders: a widget is the reply itself, not an
  // attachment to fetch on request. The read is the gateway's bounded text
  // preview of a file the agent named; nothing in it runs.
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SandboxPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file != widget.file) _load();
  }

  /// Starts a read. Sets state directly: callers run before a build or
  /// inside setState.
  void _load() {
    final generation = ++_generation;
    final reader = widget.readHtml;
    _document = null;
    _truncated = false;
    _failed = false;
    _missing = reader == null || !htmlFilePath(widget.file);
    if (reader != null && !_missing) {
      unawaited(_read(reader, widget.file, generation));
    }
  }

  Future<void> _read(
    WidgetHtmlReader reader,
    String file,
    int generation,
  ) async {
    final source = await reader(file);
    final document = source == null
        ? null
        : await parseSandboxedPage(source.text);
    if (!mounted || generation != _generation) return;
    setState(() {
      _document = document;
      _failed = source == null;
      _missing = source != null && document == null;
      _truncated = source?.truncated ?? false;
    });
  }

  Future<void> _send(String prompt) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final decision = evaluateWidgetIntent(
      data: {
        'type': intentMessageType,
        'token': _token,
        'id': 1,
        'prompt': prompt,
      },
      token: _token,
      nowMs: now,
      lastAcceptedAtMs: _lastAcceptedAt,
      userGesture: true,
      origin: opaqueWidgetOrigin(widget.file),
      expectedOrigin: opaqueWidgetOrigin(widget.file),
      inFlight: _delivering,
    );
    if (decision is! IntentAccepted) {
      final reason = decision is IntentRejected ? decision.error : 'invalid';
      setState(() => _status = reason);
      return;
    }
    final deliver = widget.onIntent;
    if (deliver == null) {
      setState(() => _status = 'undelivered');
      return;
    }
    // Stamp the acceptance before the first await: a second tap during a
    // slow delivery must see both the stamp and the in-flight delivery.
    _lastAcceptedAt = now;
    _delivering = true;
    try {
      await deliver(decision.prompt);
      if (mounted) setState(() => _status = _sent);
    } catch (_) {
      if (mounted) setState(() => _status = 'undelivered');
    } finally {
      _delivering = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.sharedL10n;
    final document = _document;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.render_widget_file(widget.file)),
            Text(l.render_widget_runs_as_text),
            // While the read runs, only the file line shows.
            if (_failed) ...[
              Text(l.attachment_download_failed),
              TextButton(
                onPressed: () => setState(_load),
                child: Text(l.render_load_widget),
              ),
            ] else if (_missing)
              Text(l.render_not_html_widget)
            else if (document != null) ...[
              if (_truncated)
                Text(
                  l.render_widget_file_truncated,
                  key: const Key('widget-file-truncated'),
                ),
              if (document.droppedActiveContent)
                Text(l.render_active_content_removed),
              Text(document.text),
              for (final control in document.controls)
                TextButton(
                  onPressed: () => unawaited(_send(control.prompt)),
                  child: Text(
                    control.label.isEmpty ? control.prompt : control.label,
                  ),
                ),
            ],
            if (_status case final status?) Text(_statusText(l, status)),
          ],
        ),
      ),
    );
  }
}

class InspectedImageTile extends StatelessWidget {
  const InspectedImageTile({super.key, required this.source, this.output});

  /// The tool row's text (Classic) or its arguments (NextGen).
  final String source;

  /// The tool result, read when [source] names no image.
  final String? output;

  @override
  Widget build(BuildContext context) {
    final output = this.output;
    final path =
        inspectedImagePath(source) ??
        (output == null ? null : inspectedImagePath(output));
    if (path == null) return const SizedBox.shrink();
    final name = path.split('/').last;
    return ListTile(
      key: Key('inspected-image-$name'),
      leading: const Icon(Icons.image_search),
      title: Text(context.sharedL10n.render_inspected_image),
      subtitle: Text(name),
    );
  }
}

/// Tool text is searched for an image path only this far. Tool arguments
/// can carry a whole data: URL; the path, when there is one, comes first.
const toolInspectChars = 2048;

final _inspectedPaths = ContentMemo<String?>(32);

/// The first image path in tool text, as the old
/// `(?:Screenshot path:\s*)?(\S+\.(?:png|jpe?g|gif|webp))` pattern found it,
/// read in one pass over the first [toolInspectChars] characters and
/// memoised. The pattern restarted at every non-space character, so a long
/// token (a base64 data: URL) took quadratic time on every rebuild.
String? inspectedImagePath(String text) {
  final head = text.length > toolInspectChars
      ? text.substring(0, toolInspectChars)
      : text;
  return _inspectedPaths.lookup(head, () {
    final path = _firstImagePath(head);
    if (path == null || path.contains('://')) return null;
    return path;
  });
}

/// Drops memoised tool-image paths, for a renderer reset.
void resetInspectedImagePaths() => _inspectedPaths.clear();

const _imageExtensions = ['png', 'jpeg', 'jpg', 'gif', 'webp'];

/// The end of the last `.png`/`.jpe?g`/`.gif`/`.webp` in text[start, end)
/// that has at least one character before its dot, or -1. Greedy `\S+`
/// kept the last one.
int _lastImageExtensionEnd(String text, int start, int end) {
  for (var dot = end - 4; dot > start; dot--) {
    if (text.codeUnitAt(dot) != 0x2e /* . */ ) continue;
    for (final extension in _imageExtensions) {
      if (dot + 1 + extension.length <= end &&
          _matchesLowerAt(text, dot + 1, extension)) {
        return dot + 1 + extension.length;
      }
    }
  }
  return -1;
}

bool _matchesLowerAt(String text, int at, String lower) {
  if (at < 0 || at + lower.length > text.length) return false;
  for (var i = 0; i < lower.length; i++) {
    var c = text.codeUnitAt(at + i);
    if (c >= 0x41 && c <= 0x5a) c |= 0x20;
    if (c != lower.codeUnitAt(i)) return false;
  }
  return true;
}

bool _endsWithLower(String text, int end, String lower) =>
    _matchesLowerAt(text, end - lower.length, lower);

String? _firstImagePath(String text) {
  var at = 0;
  while (at < text.length) {
    while (at < text.length && isMarkupSpace(text.codeUnitAt(at))) {
      at++;
    }
    final start = at;
    while (at < text.length && !isMarkupSpace(text.codeUnitAt(at))) {
      at++;
    }
    if (start == at) break;
    final own = _lastImageExtensionEnd(text, start, at);
    if (own >= 0) return text.substring(start, own);
    // `Screenshot path:` may join this token to the next one, with or
    // without whitespace after the colon.
    if (_endsWithLower(text, at, 'screenshot') &&
        at + 6 <= text.length &&
        text.codeUnitAt(at) == 0x20 &&
        _matchesLowerAt(text, at + 1, 'path:')) {
      var from = at + 6;
      while (from < text.length && isMarkupSpace(text.codeUnitAt(from))) {
        from++;
      }
      var to = from;
      while (to < text.length && !isMarkupSpace(text.codeUnitAt(to))) {
        to++;
      }
      final joined = _lastImageExtensionEnd(text, from, to);
      if (joined >= 0) return text.substring(from, joined);
    }
  }
  return null;
}
