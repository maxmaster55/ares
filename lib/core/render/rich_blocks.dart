import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'artifact_library.dart';

class DiagramNode {
  const DiagramNode(this.id, this.label, this.shape);

  final String id;
  final String label;
  final String shape;
}

class DiagramEdge {
  const DiagramEdge(this.from, this.to, [this.label]);

  final String from;
  final String to;
  final String? label;
}

class DiagramModel {
  const DiagramModel({
    required this.kind,
    required this.direction,
    required this.nodes,
    required this.edges,
  });

  final String kind;
  final String direction;
  final List<DiagramNode> nodes;
  final List<DiagramEdge> edges;
}

final _nodeShape = RegExp(
  r'^([A-Za-z0-9_]+)(?:\[([^\]]+)\]|\{([^}]+)\]|\(([^)]+)\))?$',
);

DiagramNode? _node(String raw) {
  final match = _nodeShape.firstMatch(raw.trim());
  if (match == null) return null;
  final id = match.group(1)!;
  final label = match.group(2) ?? match.group(3) ?? match.group(4) ?? id;
  final shape = match.group(2) != null
      ? 'rect'
      : match.group(3) != null
      ? 'diamond'
      : 'round';
  return DiagramNode(id, label, shape);
}

/// Diagram source beyond these bounds is not drawn; it stays a code fence.
const mermaidMaxChars = 16 * 1024;
const mermaidMaxLines = 300;
const mermaidMaxLineChars = 400;

final _mermaidModels = ContentMemo<DiagramModel?>(32);

/// `from -->|label| to`, `from --> to` or `from --- to`. The first arrow
/// with whitespace on both sides wins, as the old lazy pattern chose. Each
/// arrow is checked in constant time apart from its label, and lines are
/// capped, so a long run of spaces cannot make the scan restart from every
/// character.
({String from, String to, String? label})? _mermaidLink(String line) {
  for (final arrow in const ['-->', '---']) {
    final labels = arrow == '-->';
    var at = line.indexOf(arrow);
    while (at >= 0) {
      if (at >= 2 && isMarkupSpace(line.codeUnitAt(at - 1))) {
        var rest = at + arrow.length;
        String? label;
        if (labels &&
            rest < line.length &&
            line.codeUnitAt(rest) == 0x7c /* | */ ) {
          final close = line.indexOf('|', rest + 1);
          if (close > rest + 1) {
            label = line.substring(rest + 1, close);
            rest = close + 1;
          }
        }
        if (rest < line.length && isMarkupSpace(line.codeUnitAt(rest))) {
          final from = line.substring(0, at).trimRight();
          final to = line.substring(rest).trim();
          if (from.isNotEmpty && to.isNotEmpty) {
            return (from: from, to: to, label: label);
          }
        }
      }
      at = line.indexOf(arrow, at + 1);
    }
  }
  return null;
}

/// `from ->> to: message` (also `->`, `-->>`): the first arrow after the
/// opening word, the shortest word after it that a `:` follows, and the
/// rest. Read in one pass; the old lazy pattern
/// `^(\S+?)\s*(-{1,2}>>|->>|->)\s*(\S+?)\s*:\s*(.+)` retried every
/// split of a long arrow chain that had no message.
(String, String, String)? _sequenceMessage(String line) {
  final n = line.length;
  var tokenEnd = 0;
  while (tokenEnd < n && !isMarkupSpace(line.codeUnitAt(tokenEnd))) {
    tokenEnd++;
  }
  bool arrowAt(int at) =>
      line.startsWith('->', at) || line.startsWith('-->>', at);
  // The arrow starts inside the first word or after the spaces that end it.
  var arrow = -1;
  for (var at = line.indexOf('-', 1); at >= 0 && at < tokenEnd;) {
    if (arrowAt(at)) {
      arrow = at;
      break;
    }
    at = line.indexOf('-', at + 1);
  }
  if (arrow < 0) {
    if (tokenEnd == 0) return null;
    var next = tokenEnd;
    while (next < n && isMarkupSpace(line.codeUnitAt(next))) {
      next++;
    }
    if (next >= n || !arrowAt(next)) return null;
    arrow = next;
  }
  final from = line.substring(0, arrow).trimRight();
  if (from.isEmpty) return null;
  for (final mark in const ['-->>', '->>', '->']) {
    if (!line.startsWith(mark, arrow)) continue;
    var start = arrow + mark.length;
    while (start < n && isMarkupSpace(line.codeUnitAt(start))) {
      start++;
    }
    var end = start;
    while (end < n && !isMarkupSpace(line.codeUnitAt(end))) {
      end++;
    }
    // The shortest target: the first `:` after its first character, or a
    // `:` after the spaces that end it; the message must not be empty.
    var colon = start + 1 < end ? line.indexOf(':', start + 1) : -1;
    if (colon < 0 || colon >= end) {
      colon = end;
      while (colon < n && isMarkupSpace(line.codeUnitAt(colon))) {
        colon++;
      }
      if (colon >= n || line.codeUnitAt(colon) != 0x3a /* : */ ) continue;
    }
    if (end <= start || colon + 1 >= n) continue;
    final to = line.substring(start, colon).trimRight();
    if (to.isEmpty) continue;
    return (from, to, line.substring(colon + 1).trim());
  }
  return null;
}

/// A bounded flowchart or sequence diagram. Anything else stays a code fence.
/// Memoised by source, so a streaming reply re-parses only a changed diagram.
DiagramModel? parseMermaid(String source) {
  if (source.length > mermaidMaxChars) return null;
  return _mermaidModels.lookup(source, () => _parseMermaid(source));
}

/// Drops memoised diagrams and prose splits, for a renderer reset or a cold
/// timing test.
void resetRichBlockCaches() {
  _mermaidModels.clear();
  _prosePieces.clear();
}

DiagramModel? _parseMermaid(String source) {
  final lines = source
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('%%'))
      .toList();
  if (lines.isEmpty || lines.length > mermaidMaxLines) return null;
  final header = lines.first.toLowerCase();
  if (header.startsWith('sequencediagram')) {
    final nodes = <String, DiagramNode>{};
    final edges = <DiagramEdge>[];
    for (final line in lines.skip(1)) {
      if (line.length > mermaidMaxLineChars) continue;
      final message = _sequenceMessage(line);
      if (message == null) continue;
      final (from, to, label) = message;
      nodes.putIfAbsent(from, () => DiagramNode(from, from, 'actor'));
      nodes.putIfAbsent(to, () => DiagramNode(to, to, 'actor'));
      edges.add(DiagramEdge(from, to, label));
    }
    if (edges.isEmpty) return null;
    return DiagramModel(
      kind: 'sequence',
      direction: 'TD',
      nodes: nodes.values.toList(),
      edges: edges,
    );
  }
  if (!header.startsWith('flowchart') && !header.startsWith('graph')) {
    return null;
  }
  final direction = header.split(RegExp(r'\s+')).length > 1
      ? header.split(RegExp(r'\s+'))[1].toUpperCase()
      : 'TD';
  final nodes = <String, DiagramNode>{};
  final edges = <DiagramEdge>[];
  for (final line in lines.skip(1)) {
    if (line.length > mermaidMaxLineChars) continue;
    final link = _mermaidLink(line);
    if (link == null) {
      final lone = _node(line);
      if (lone != null) nodes.putIfAbsent(lone.id, () => lone);
      continue;
    }
    final from = _node(link.from);
    final to = _node(link.to);
    if (from == null || to == null) continue;
    nodes[from.id] = from;
    nodes[to.id] = to;
    edges.add(DiagramEdge(from.id, to.id, link.label));
  }
  if (nodes.isEmpty) return null;
  return DiagramModel(
    kind: 'flowchart',
    direction: direction == 'LR' || direction == 'RL' ? direction : 'TD',
    nodes: nodes.values.toList(),
    edges: edges,
  );
}

class SvgOp {
  const SvgOp(this.name, this.attrs);

  final String name;
  final Map<String, String> attrs;
}

class SvgDrawing {
  const SvgDrawing(this.viewBox, this.ops);

  final String viewBox;
  final List<SvgOp> ops;
}

const _svgAllowed = {
  'svg',
  'g',
  'rect',
  'circle',
  'ellipse',
  'line',
  'polyline',
  'polygon',
  'text',
  'title',
};

/// Paints a small SVG subset. Scripts, foreign objects and external URLs are
/// dropped rather than loaded.
SvgDrawing? parseSafeSvg(String source) {
  XmlDocument document;
  try {
    document = XmlDocument.parse(source);
  } on XmlException {
    return null;
  }
  final root = document.rootElement;
  if (root.name.local.toLowerCase() != 'svg') return null;
  final ops = <SvgOp>[];
  var refused = false;
  void walk(XmlElement element) {
    final name = element.name.local.toLowerCase();
    if (name == 'script' ||
        name == 'foreignobject' ||
        name == 'iframe' ||
        name == 'image' ||
        name == 'use') {
      refused = true;
      return;
    }
    for (final attribute in element.attributes) {
      final key = attribute.name.local.toLowerCase();
      final value = attribute.value.trim().toLowerCase();
      if (key.startsWith('on') ||
          value.startsWith('javascript:') ||
          (key == 'href' && value.contains('://'))) {
        refused = true;
        return;
      }
    }
    if (_svgAllowed.contains(name) && name != 'svg' && name != 'g') {
      ops.add(
        SvgOp(name, {
          for (final attribute in element.attributes)
            attribute.name.local: attribute.value,
          if (name == 'text') 'text': element.innerText,
        }),
      );
    }
    for (final child in element.childElements) {
      walk(child);
    }
  }

  walk(root);
  if (refused) return null;
  return SvgDrawing(root.getAttribute('viewBox') ?? '', ops);
}

class MathPiece {
  const MathPiece(this.source, {required this.display});

  final String source;
  final bool display;
}

class AlertPiece {
  const AlertPiece(this.type, this.body);

  final String type;
  final String body;
}

class TablePiece {
  const TablePiece(this.headers, this.rows);

  final List<String> headers;
  final List<List<String>> rows;
}

class DirectivePiece {
  const DirectivePiece(this.name, this.attrs, this.raw);

  final String name;
  final Map<String, String> attrs;
  final String raw;
}

class ListingCard {
  const ListingCard({
    required this.address,
    this.price,
    this.beds,
    this.baths,
    this.size,
    this.note,
    this.facts = const [],
    this.catches = const [],
  });

  final String address;
  final String? price;
  final double? beds;
  final double? baths;
  final String? size;
  final String? note;
  final List<String> facts;
  final List<String> catches;
}

class SandboxControl {
  const SandboxControl(this.prompt, this.label);

  final String prompt;
  final String label;
}

class SandboxDocument {
  const SandboxDocument({
    required this.text,
    required this.controls,
    required this.droppedActiveContent,
  });

  final String text;
  final List<SandboxControl> controls;
  final bool droppedActiveContent;
}

const _droppedTags = {
  'script',
  'iframe',
  'object',
  'embed',
  'link',
  'meta',
  'base',
  'style',
};

const _tableCells = {'td', 'th'};
const _tableParts = {'table', 'thead', 'tbody', 'tfoot', 'tr'};

/// Reads agent HTML as a document. No script, handler or external frame runs.
SandboxDocument? parseSandboxedHtml(String source) {
  if (!RegExp(r'<[a-z]', caseSensitive: false).hasMatch(source)) return null;
  final document = html_parser.parse(source);
  var dropped = false;
  final controls = <SandboxControl>[];
  final text = StringBuffer();

  void walk(dom.Node node) {
    if (node is dom.Element) {
      final name = node.localName?.toLowerCase() ?? '';
      if (_droppedTags.contains(name)) {
        dropped = true;
        return;
      }
      final attrs = node.attributes;
      for (final entry in attrs.entries.toList()) {
        final key = entry.key.toString().toLowerCase();
        final value = entry.value.trim().toLowerCase();
        if (key.startsWith('on') ||
            value.startsWith('javascript:') ||
            (key == 'src' && value.contains('://')) ||
            (key == 'href' && value.startsWith('javascript:'))) {
          dropped = true;
          attrs.remove(entry.key);
        }
      }
      final send = attrs['data-hermes-send'];
      if (send != null && send.trim().isNotEmpty) {
        controls.add(SandboxControl(send.trim(), node.text.trim()));
        return;
      }
      // A table reads one row per line, its cells split by ` | `.
      if (_tableCells.contains(name) && node.previousElementSibling != null) {
        text.write(' | ');
      }
      for (final child in node.nodes) {
        walk(child);
      }
      if (name == 'p' ||
          name == 'div' ||
          name == 'br' ||
          name == 'tr' ||
          name.startsWith('h')) {
        text.write('\n');
      }
      return;
    }
    if (node is dom.Text) {
      // Source indentation between rows and cells is not cell text.
      if (_tableParts.contains(node.parent?.localName) &&
          node.text.trim().isEmpty) {
        return;
      }
      text.write(node.text);
    }
  }

  final body = document.body;
  if (body != null) walk(body);
  return SandboxDocument(
    text: text.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim(),
    controls: controls,
    droppedActiveContent: dropped,
  );
}

bool htmlFilePath(String path) {
  final name = path.split('?').first.split('/').last.toLowerCase();
  return name.endsWith('.html') ||
      name.endsWith('.htm') ||
      name.endsWith('.xhtml');
}

/// A `::name{…}` body longer than this stays prose. Directive attributes
/// are short; a longer body is agent text, not a card.
const directiveMaxBodyChars = 1024;

bool _wordChar(int c) =>
    (c >= 0x61 && c <= 0x7a) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x5f;

/// `key="value"` and `key='value'` pairs, read in one pass. The old
/// `(\w+)\s*=` pattern restarted at every word character, so a long word
/// run without `=` took quadratic time on every rebuild.
Map<String, String> _directiveAttrs(String raw) {
  final attrs = <String, String>{};
  var floor = 0;
  var eq = raw.indexOf('=');
  while (eq >= 0) {
    var keyEnd = eq;
    while (keyEnd > floor && isMarkupSpace(raw.codeUnitAt(keyEnd - 1))) {
      keyEnd--;
    }
    var keyStart = keyEnd;
    while (keyStart > floor && _wordChar(raw.codeUnitAt(keyStart - 1))) {
      keyStart--;
    }
    var at = eq + 1;
    while (at < raw.length && isMarkupSpace(raw.codeUnitAt(at))) {
      at++;
    }
    var next = eq + 1;
    if (keyStart < keyEnd && at < raw.length) {
      final quote = raw.codeUnitAt(at);
      if (quote == 0x22 /* " */ || quote == 0x27 /* ' */ ) {
        final close = raw.indexOf(String.fromCharCode(quote), at + 1);
        if (close > at) {
          attrs[raw.substring(keyStart, keyEnd)] = raw.substring(at + 1, close);
          floor = close + 1;
          next = close + 1;
        }
      }
    }
    eq = raw.indexOf('=', next);
  }
  return attrs;
}

bool _directiveNameStart(int c) => c >= 0x61 && c <= 0x7a;

bool _directiveNameChar(int c) =>
    _directiveNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2d;

/// `::name{body}` with a lower-case name and a body free of braces, as the
/// old pattern matched, read once from each `::`. A body over
/// [directiveMaxBodyChars] is left as prose.
void _directives(String text, List<_Hit> into) {
  var at = text.indexOf('::');
  while (at >= 0) {
    var i = at + 2;
    if (i < text.length && _directiveNameStart(text.codeUnitAt(i))) {
      i++;
      while (i < text.length && _directiveNameChar(text.codeUnitAt(i))) {
        i++;
      }
      if (i < text.length && text.codeUnitAt(i) == 0x7b /* { */ ) {
        final limit = i + 1 + directiveMaxBodyChars;
        var j = i + 1;
        while (j < text.length && j <= limit) {
          final c = text.codeUnitAt(j);
          if (c == 0x7b || c == 0x7d) break;
          j++;
        }
        if (j < text.length && j <= limit && text.codeUnitAt(j) == 0x7d) {
          into.add(
            _Hit(
              at,
              j + 1,
              DirectivePiece(
                text.substring(at + 2, i),
                _directiveAttrs(text.substring(i + 1, j)),
                text.substring(at, j + 1),
              ),
            ),
          );
          at = text.indexOf('::', j + 1);
          continue;
        }
      }
    }
    at = text.indexOf('::', at + 1);
  }
}

const _alertTypes = {'note', 'tip', 'important', 'warning', 'caution'};
final _displayMath = RegExp(r'\$\$([^$]+)\$\$');
final _inlineMath = RegExp(r'(?<!\$)\$([^$\n]+)\$(?!\$)');

bool _mathLike(String body) =>
    body.contains(r'\') || body.contains('^') || body.contains('_');

List<String> _cells(String line) {
  final body = line.trim();
  final cells = <String>[];
  final cell = StringBuffer();
  var i = body.startsWith('|') ? 1 : 0;
  for (; i < body.length; i++) {
    final char = body.codeUnitAt(i);
    if (char == 0x5c && i + 1 < body.length) {
      final next = body.codeUnitAt(++i);
      // GFM removes the pipe escape before inline parsing, including code.
      if (next != 0x7c) cell.writeCharCode(char);
      cell.writeCharCode(next);
    } else if (char == 0x7c) {
      cells.add(cell.toString().trim());
      cell.clear();
    } else {
      cell.writeCharCode(char);
    }
  }
  if (!body.endsWith('|') || cell.isNotEmpty) {
    cells.add(cell.toString().trim());
  }
  return cells;
}

/// `:?-{3,}:?` after trimming.
bool _separatorCell(String cell) {
  var start = 0;
  var end = cell.length;
  if (start < end && cell.codeUnitAt(start) == 0x3a /* : */ ) start++;
  if (end > start && cell.codeUnitAt(end - 1) == 0x3a) end--;
  if (end - start < 3) return false;
  for (var i = start; i < end; i++) {
    if (cell.codeUnitAt(i) != 0x2d /* - */ ) return false;
  }
  return true;
}

/// A table separator row: two or more `:?-{3,}:?` cells split by `|`,
/// with optional outer pipes, as
/// `^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$` matched. Read by
/// splitting: the pattern's two `\s*` around the optional pipe made a long
/// run of spaces quadratic.
bool _separator(String line) {
  var body = line.trim();
  if (body.startsWith('|')) body = body.substring(1);
  if (body.endsWith('|')) body = body.substring(0, body.length - 1);
  final cells = body.split('|');
  if (cells.length < 2) return false;
  for (final cell in cells) {
    if (!_separatorCell(cell.trim())) return false;
  }
  return true;
}

List<ListingCard> parseListings(String code) {
  Object? data;
  try {
    data = jsonDecode(code);
  } on FormatException {
    return const [];
  }
  final entries = data is List
      ? data
      : data is Map && data['listings'] is List
      ? data['listings'] as List
      : [data];
  final cards = <ListingCard>[];
  for (final entry in entries.take(12)) {
    if (entry is! Map) continue;
    final address = (entry['address'] ?? entry['title'] ?? '')
        .toString()
        .trim();
    if (address.isEmpty) continue;
    double? count(Object? value) {
      final parsed = value is num
          ? value.toDouble()
          : value is String
          ? double.tryParse(value.trim())
          : null;
      if (parsed == null || parsed <= 0 || parsed > 99) return null;
      return (parsed * 10).round() / 10;
    }

    List<String> strings(Object? value) => value is List
        ? [
            for (final item in value.take(8))
              if (item.toString().trim().isNotEmpty) item.toString().trim(),
          ]
        : const [];
    cards.add(
      ListingCard(
        address: address,
        price: entry['price']?.toString(),
        beds: count(entry['beds']),
        baths: count(entry['baths']),
        size: (entry['size'] ?? entry['sqft'])?.toString(),
        note: entry['note']?.toString(),
        facts: strings(entry['facts']),
        catches: strings(entry['catches']),
      ),
    );
  }
  return cards;
}

sealed class TranscriptPiece {
  const TranscriptPiece();
}

class ProsePiece extends TranscriptPiece {
  const ProsePiece(this.text);

  final String text;
}

class RichPiece extends TranscriptPiece {
  const RichPiece(this.value);

  final Object value;
}

List<TranscriptPiece> _piecesFromProse(String text, {bool tablesOnly = false}) {
  if (text.isEmpty) return const [];
  final matches = <_Hit>[];
  void take(RegExp pattern, Object? Function(RegExpMatch match) build) {
    for (final match in pattern.allMatches(text)) {
      final value = build(match);
      if (value != null) {
        matches.add(_Hit(match.start, match.end, value));
      }
    }
  }

  if (!tablesOnly) {
    _directives(text, matches);
    _alerts(text, matches);
    take(_displayMath, (match) {
      final body = match.group(1)!.trim();
      return _mathLike(body) ? MathPiece(body, display: true) : null;
    });
    take(_inlineMath, (match) {
      final body = match.group(1)!.trim();
      return _mathLike(body) ? MathPiece(body, display: false) : null;
    });
  }
  final lines = text.split('\n');
  var offset = 0;
  var row = 0;
  while (row < lines.length) {
    final lineStart = offset;
    if (lines[row].contains('|') &&
        row + 1 < lines.length &&
        _separator(lines[row + 1]) &&
        _cells(lines[row]).length == _cells(lines[row + 1]).length) {
      final headers = _cells(lines[row]);
      final rows = <List<String>>[];
      var end = offset + lines[row].length + 1 + lines[row + 1].length;
      var next = row + 2;
      while (next < lines.length && lines[next].contains('|')) {
        rows.add(_cells(lines[next]));
        end += 1 + lines[next].length;
        next++;
      }
      if (end <= text.length) {
        matches.add(_Hit(lineStart, end, TablePiece(headers, rows)));
      }
      row = next;
      offset = end + 1;
      continue;
    }
    // Provider links (YouTube, TikTok, Maps…) stay ordinary Markdown links:
    // Ares embeds no third-party player, so there is nothing to consent to.
    offset += lines[row].length + 1;
    row++;
  }

  if (matches.isEmpty) return [ProsePiece(text)];
  matches.sort((a, b) => a.start.compareTo(b.start));
  final kept = <_Hit>[];
  var cursor = 0;
  for (final hit in matches) {
    if (hit.start < cursor || hit.end > text.length) continue;
    kept.add(hit);
    cursor = hit.end;
  }
  final pieces = <TranscriptPiece>[];
  cursor = 0;
  for (final hit in kept) {
    if (hit.start > cursor) {
      pieces.add(ProsePiece(text.substring(cursor, hit.start)));
    }
    pieces.add(RichPiece(hit.value));
    cursor = hit.end;
  }
  if (cursor < text.length) pieces.add(ProsePiece(text.substring(cursor)));
  return pieces.where((piece) {
    return piece is! ProsePiece || piece.text.trim().isNotEmpty;
  }).toList();
}

final _quoteMark = RegExp(r'^>\s?');

/// `> [!NOTE]` and the other alert headers, without the leading `>` marks.
String? _alertHeader(String line) {
  if (!line.startsWith('>')) return null;
  var i = 0;
  while (i < line.length &&
      (line.codeUnitAt(i) == 0x3e || isMarkupSpace(line.codeUnitAt(i)))) {
    i++;
  }
  if (!line.startsWith('[!', i)) return null;
  final close = line.indexOf(']', i + 2);
  if (close < 0) return null;
  final type = line.substring(i + 2, close).toLowerCase();
  if (!_alertTypes.contains(type)) return null;
  for (var j = close + 1; j < line.length; j++) {
    if (!isMarkupSpace(line.codeUnitAt(j))) return null;
  }
  return type;
}

/// GitHub-style alert blocks, read one line at a time. The old pattern
/// nested `(?:>\s*)+` and restarted at every line, so a reply made of many
/// `>` lines took quadratic time on every rebuild.
void _alerts(String text, List<_Hit> into) {
  final lines = text.split('\n');
  var offset = 0;
  var row = 0;
  while (row < lines.length) {
    final start = offset;
    final type = _alertHeader(lines[row]);
    offset += lines[row].length + 1;
    row++;
    // The header needs its own line break, as the pattern required.
    if (type == null || row >= lines.length) continue;
    final body = <String>[];
    var end = offset;
    while (row < lines.length && lines[row].startsWith('>')) {
      body.add(lines[row].replaceFirst(_quoteMark, ''));
      offset += lines[row].length + 1;
      end = offset;
      row++;
    }
    into.add(
      _Hit(
        start,
        end > text.length ? text.length : end,
        AlertPiece(type, body.join('\n').trim()),
      ),
    );
  }
}

class _Hit {
  const _Hit(this.start, this.end, this.value);

  final int start;
  final int end;
  final Object value;
}

final _prosePieces = ContentMemo<List<TranscriptPiece>>(64);
final _tablePieces = ContentMemo<List<TranscriptPiece>>(16);

/// Document previews opt into table layout without executing chat directives.
List<TranscriptPiece> splitTableProse(String text) => _tablePieces.lookup(
  text,
  () => List<TranscriptPiece>.unmodifiable(
    _piecesFromProse(text, tablesOnly: true),
  ),
);

/// Splits reply prose into Markdown and rich pieces. Memoised by text, so
/// every unchanged paragraph of a streaming reply skips the scan.
List<TranscriptPiece> splitRichProse(String text) => _prosePieces.lookup(
  text,
  () => List<TranscriptPiece>.unmodifiable(_piecesFromProse(text)),
);
