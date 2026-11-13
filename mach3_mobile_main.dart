import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const Mach3MobileApp());

const cBg = Color(0xFF101820);
const cPanel = Color(0xFF1B2935);
const cPanel2 = Color(0xFF263746);
const cAccent = Color(0xFFFFA52F);
const cGreen = Color(0xFF31C48D);
const cRed = Color(0xFFE45B5B);
const cBlue = Color(0xFF55B8F2);

class Mach3MobileApp extends StatelessWidget {
  const Mach3MobileApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Mach3 Mobile',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: cBg,
          colorScheme: const ColorScheme.dark(
            primary: cAccent,
            secondary: cGreen,
            surface: cPanel,
          ),
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        home: const Mach3Home(),
      );
}

class AxisPosition {
  double x, y, z, a;
  AxisPosition(this.x, this.y, this.z, this.a);
  AxisPosition copy() => AxisPosition(x, y, z, a);
  double get(String axis) => switch (axis) {
        'X' => x,
        'Y' => y,
        'Z' => z,
        'A' => a,
        _ => 0,
      };
  void set(String axis, double value) {
    switch (axis) {
      case 'X': x = value; break;
      case 'Y': y = value; break;
      case 'Z': z = value; break;
      case 'A': a = value; break;
    }
  }
}

class MotionSegment {
  final int sourceLine;
  final Offset start, end;
  final bool rapid;
  const MotionSegment(this.sourceLine, this.start, this.end, this.rapid);
}

class ParseIssue {
  final int line;
  final String message;
  const ParseIssue(this.line, this.message);
}

class GCodeAnalysis {
  final List<MotionSegment> segments;
  final List<ParseIssue> issues;
  final int sourceLines;
  final AxisPosition finalPosition;
  final double minX, maxX, minY, maxY, minZ, maxZ;
  final String units;
  final int rapidCount, feedCount, arcCount;
  const GCodeAnalysis({
    required this.segments,
    required this.issues,
    required this.sourceLines,
    required this.finalPosition,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.minZ,
    required this.maxZ,
    required this.units,
    required this.rapidCount,
    required this.feedCount,
    required this.arcCount,
  });
}

/// Offline XY-plane G-code analyzer. It does not execute machine commands.
/// Supports G0/G1/G2/G3, G17, G20/G21, G90/G91, I/J and R arcs.
/// Unknown commands are ignored; malformed arc geometry is reported.
class GCodeParser {
  static final _word = RegExp(r'([A-Z])\s*([+-]?(?:\d+\.?\d*|\.\d+))');

  static GCodeAnalysis parse(String source) {
    var pos = AxisPosition(0, 0, 0, 0);
    var unitsScale = 1.0;
    var units = 'mm';
    var absolute = true;
    var planeXY = true;
    var motion = 0;
    final segments = <MotionSegment>[];
    final issues = <ParseIssue>[];
    var rapidCount = 0, feedCount = 0, arcCount = 0;

    var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0;
    var minZ = 0.0, maxZ = 0.0;

    void bounds(AxisPosition p) {
      minX = math.min(minX, p.x).toDouble();
      maxX = math.max(maxX, p.x).toDouble();
      minY = math.min(minY, p.y).toDouble();
      maxY = math.max(maxY, p.y).toDouble();
      minZ = math.min(minZ, p.z).toDouble();
      maxZ = math.max(maxZ, p.z).toDouble();
    }

    final lines = source.split(RegExp(r'\r?\n'));
    for (var li = 0; li < lines.length; li++) {
      var line = lines[li].replaceAll(RegExp(r'\([^)]*\)'), '');
      line = line.split(';').first.toUpperCase();
      final words = <String, double>{};
      for (final m in _word.allMatches(line)) {
        final v = double.tryParse(m.group(2)!);
        if (v != null) words[m.group(1)!] = v;
      }
      if (words.isEmpty) continue;

      // Read all G words rather than assuming only one G-code per block.
      for (final m in RegExp(r'G\s*(\d+(?:\.\d+)?)').allMatches(line)) {
        final g = double.tryParse(m.group(1)!) ?? -1;
        if (g == 0) motion = 0;
        if (g == 1) motion = 1;
        if (g == 2) motion = 2;
        if (g == 3) motion = 3;
        if (g == 17) planeXY = true;
        if (g == 18 || g == 19) planeXY = false;
        if (g == 20) { unitsScale = 25.4; units = 'inch'; }
        if (g == 21) { unitsScale = 1; units = 'mm'; }
        if (g == 90) absolute = true;
        if (g == 91) absolute = false;
      }

      final old = pos.copy();
      final next = pos.copy();
      for (final axis in ['X', 'Y', 'Z', 'A']) {
        if (words.containsKey(axis)) {
          final value = words[axis]! * (axis == 'A' ? 1 : unitsScale);
          next.set(axis, absolute ? value : pos.get(axis) + value);
        }
      }
      final hasMove = ['X', 'Y', 'Z', 'A'].any(words.containsKey);
      if (!hasMove) continue;

      if (motion == 2 || motion == 3) {
        if (!planeXY) {
          issues.add(ParseIssue(li + 1, 'Arc outside XY plane is not drawn.'));
          pos = next;
          bounds(pos);
          continue;
        }
        final sx = old.x, sy = old.y, ex = next.x, ey = next.y;
        double cx, cy, radius, startAngle, sweep;
        if (words.containsKey('I') || words.containsKey('J')) {
          cx = sx + (words['I'] ?? 0) * unitsScale;
          cy = sy + (words['J'] ?? 0) * unitsScale;
          radius = math.sqrt((sx - cx) * (sx - cx) + (sy - cy) * (sy - cy));
          startAngle = math.atan2(sy - cy, sx - cx);
          final endAngle = math.atan2(ey - cy, ex - cx);
          sweep = endAngle - startAngle;
          if (motion == 2 && sweep >= 0) sweep -= 2 * math.pi;
          if (motion == 3 && sweep <= 0) sweep += 2 * math.pi;
        } else if (words.containsKey('R')) {
          final r = words['R']! * unitsScale;
          final dx = ex - sx, dy = ey - sy;
          final chord = math.sqrt(dx * dx + dy * dy);
          if (chord == 0 || chord > 2 * r.abs()) {
            issues.add(ParseIssue(li + 1, 'Invalid R arc geometry.'));
            pos = next;
            continue;
          }
          final midX = (sx + ex) / 2, midY = (sy + ey) / 2;
          final h = math.sqrt(math.max(0, r * r - chord * chord / 4));
          final perpX = -dy / chord, perpY = dx / chord;
          final candidates = [
            Offset(midX + perpX * h, midY + perpY * h),
            Offset(midX - perpX * h, midY - perpY * h),
          ];
          Offset? chosen;
          double chosenSweep = 0;
          for (final center in candidates) {
            final sa = math.atan2(sy - center.dy, sx - center.dx);
            final ea = math.atan2(ey - center.dy, ex - center.dx);
            var sw = ea - sa;
            if (motion == 2 && sw >= 0) sw -= 2 * math.pi;
            if (motion == 3 && sw <= 0) sw += 2 * math.pi;
            final major = sw.abs() > math.pi;
            if ((r < 0) == major) { chosen = center; chosenSweep = sw; break; }
          }
          chosen ??= candidates.first;
          cx = chosen.dx; cy = chosen.dy;
          radius = math.sqrt((sx - cx) * (sx - cx) + (sy - cy) * (sy - cy));
          startAngle = math.atan2(sy - cy, sx - cx);
          sweep = chosenSweep;
        } else {
          issues.add(ParseIssue(li + 1, 'Arc requires I/J or R.'));
          pos = next;
          continue;
        }

        final steps = math.max(8, (sweep.abs() * 24).ceil());
        var previous = Offset(sx, sy);
        for (var step = 1; step <= steps; step++) {
          final a = startAngle + sweep * step / steps;
          final point = step == steps
              ? Offset(ex, ey)
              : Offset(cx + radius * math.cos(a), cy + radius * math.sin(a));
          segments.add(MotionSegment(li + 1, previous, point, false));
          previous = point;
        }
        arcCount++;
        feedCount++;
      } else {
        if (old.x != next.x || old.y != next.y) {
          segments.add(MotionSegment(li + 1, Offset(old.x, old.y),
              Offset(next.x, next.y), motion == 0));
          if (motion == 0) { rapidCount++; } else { feedCount++; }
        }
      }
      pos = next;
      bounds(pos);
    }

    return GCodeAnalysis(
      segments: segments,
      issues: issues,
      sourceLines: lines.length,
      finalPosition: pos,
      minX: minX, maxX: maxX, minY: minY, maxY: maxY,
      minZ: minZ, maxZ: maxZ, units: units,
      rapidCount: rapidCount, feedCount: feedCount, arcCount: arcCount,
    );
  }
}

class Mach3Home extends StatefulWidget {
  const Mach3Home({super.key});
  @override
  State<Mach3Home> createState() => _Mach3HomeState();
}

class _Mach3HomeState extends State<Mach3Home> {
  int page = 0;
  String fileName = 'No program loaded';
  String source = '';
  GCodeAnalysis? analysis;
  final mdi = TextEditingController();
  final mdiHistory = <String>[];
  final ip = TextEditingController();
  final port = TextEditingController(text: '5000');
  String units = 'mm', workSystem = 'G54';
  double jogStep = 1, jogSpeed = 25;
  bool showRapid = true, showFeed = true;
  bool singleBlock = false, optionalStop = false, blockDelete = false;
  bool spindleOn = false, floodOn = false, mistOn = false;
  final Map<String, Map<String, double>> offsets = {
    for (final g in ['G54', 'G55', 'G56', 'G57', 'G58', 'G59'])
      g: {'X': 0, 'Y': 0, 'Z': 0},
  };
  final List<Map<String, String>> tools = [
    {'number': '1', 'diameter': '6.0', 'length': '0.0', 'description': 'End mill'},
    {'number': '2', 'diameter': '3.0', 'length': '0.0', 'description': 'Drill'},
  ];

  final names = const [
    'Program Run', 'MDI', 'Toolpath', 'Jog',
    'Offsets', 'Tool Table', 'Diagnostics', 'Settings'
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    mdi.dispose(); ip.dispose(); port.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      units = p.getString('units') ?? 'mm';
      workSystem = p.getString('work') ?? 'G54';
      jogStep = p.getDouble('step') ?? 1;
      jogSpeed = p.getDouble('speed') ?? 25;
      ip.text = p.getString('ip') ?? '';
      port.text = p.getString('port') ?? '5000';
      final savedOffsets = p.getString('offsets');
      if (savedOffsets != null) {
        try {
          final decoded = jsonDecode(savedOffsets) as Map<String, dynamic>;
          for (final g in offsets.keys) {
            if (decoded[g] is Map) {
              for (final a in ['X', 'Y', 'Z']) {
                offsets[g]![a] = (decoded[g][a] as num?)?.toDouble() ?? 0;
              }
            }
          }
        } catch (_) {}
      }
      final savedTools = p.getString('tools');
      if (savedTools != null) {
        try {
          final list = (jsonDecode(savedTools) as List).cast<Map>();
          tools
            ..clear()
            ..addAll(list.map((e) => e.map((k, v) => MapEntry('$k', '$v'))));
        } catch (_) {}
      }
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('units', units);
    await p.setString('work', workSystem);
    await p.setDouble('step', jogStep);
    await p.setDouble('speed', jogSpeed);
    await p.setString('ip', ip.text);
    await p.setString('port', port.text);
    await p.setString('offsets', jsonEncode(offsets));
    await p.setString('tools', jsonEncode(tools));
  }

  void _message(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(s)));

  Future<void> _openFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['nc', 'tap', 'gcode', 'cnc', 'txt', 'ngc'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    if (f.bytes == null) { _message('تعذر قراءة الملف من الهاتف'); return; }
    final text = utf8.decode(f.bytes!, allowMalformed: true);
    final parsed = GCodeParser.parse(text);
    setState(() {
      fileName = f.name;
      source = text;
      analysis = parsed;
      page = 0;
    });
    _message('تم تحميل الملف وتحليله محليًا');
  }

  Widget _panel(String title, Widget child, {Widget? action}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cPanel,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: const TextStyle(
              color: cAccent, fontWeight: FontWeight.bold, fontSize: 15))),
            if (action != null) action,
          ]),
          const SizedBox(height: 12),
          child,
        ]),
      );

  Widget _notice(String text, {Color color = cAccent}) => Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: color.withOpacity(.12),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: color.withOpacity(.35)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline, color: color, size: 19),
          const SizedBox(width: 9),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ]),
      );

  Widget _metric(String label, String value) => Expanded(
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 5),
          decoration: BoxDecoration(color: cBg, borderRadius: BorderRadius.circular(9)),
          child: Column(children: [
            Text(label, style: const TextStyle(color: cAccent, fontSize: 11)),
            const SizedBox(height: 5),
            Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis),
          ]),
        ),
      );

  Widget _action(String label, VoidCallback? onTap, {Color color = cPanel2, IconData? icon}) =>
      SizedBox(height: 45, child: FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon ?? Icons.circle, size: 16),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: FilledButton.styleFrom(backgroundColor: color,
          disabledBackgroundColor: Colors.white10,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9))),
      ));

  Widget _runPage() => ListView(padding: const EdgeInsets.all(12), children: [
    _panel('PROGRAM FILE', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 5),
      Text(analysis == null ? 'لم يتم تحميل ملف' :
        '${analysis!.sourceLines} سطر | ${analysis!.segments.length} مقطع حركة',
        style: const TextStyle(color: Colors.white60)),
      const SizedBox(height: 12),
      _action('OPEN G-CODE FILE', _openFile, color: cGreen, icon: Icons.folder_open),
    ])),
    _panel('PROGRAM SUMMARY', Row(children: [
      _metric('Units', analysis?.units ?? '--'),
      _metric('Rapid', '${analysis?.rapidCount ?? 0}'),
      _metric('Feed', '${analysis?.feedCount ?? 0}'),
    ])),
    _panel('PROGRAM CONTROL', Column(children: [
      _notice('تشغيل وإيقاف الماكينة يحتاجان اتصالًا حقيقيًا مع Mach3. الأزرار التالية غير مفعلة عمدًا.'),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _action('CYCLE START', null, color: cGreen, icon: Icons.play_arrow)),
        const SizedBox(width: 7),
        Expanded(child: _action('FEED HOLD', null, color: cAccent, icon: Icons.pause)),
      ]),
      const SizedBox(height: 7),
      _action('STOP PROGRAM', null, color: cRed, icon: Icons.stop),
    ])),
    _panel('OPTIONS', Column(children: [
      SwitchListTile(value: singleBlock, onChanged: (v) => setState(() => singleBlock = v), title: const Text('Single Block')),
      SwitchListTile(value: blockDelete, onChanged: (v) => setState(() => blockDelete = v), title: const Text('Block Delete')),
      SwitchListTile(value: optionalStop, onChanged: (v) => setState(() => optionalStop = v), title: const Text('Optional Stop')),
    ])),
    _panel('G-CODE TEXT', SizedBox(height: 300, child: source.isEmpty
      ? const Center(child: Text('No program loaded'))
      : ListView.builder(itemCount: source.split('\n').length, itemBuilder: (c, i) {
          final lines = source.split('\n');
          return Padding(padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('${(i+1).toString().padLeft(5)}  ${lines[i]}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11)));
        }))),
    if (analysis != null && analysis!.issues.isNotEmpty)
      _panel('PARSER WARNINGS', Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: analysis!.issues.take(30).map((e) => Text('Line ${e.line}: ${e.message}',
          style: const TextStyle(color: cAccent, fontSize: 12))).toList())),
  ]);

  Widget _mdiPage() => ListView(padding: const EdgeInsets.all(12), children: [
    _panel('MANUAL DATA INPUT', Column(children: [
      TextField(controller: mdi, decoration: const InputDecoration(
        labelText: 'G-code command', hintText: 'G0 X10 Y20')),
      const SizedBox(height: 10),
      _action('ADD TO LOCAL HISTORY', () {
        final value = mdi.text.trim().toUpperCase();
        if (value.isEmpty) return;
        setState(() { mdiHistory.insert(0, value); mdi.clear(); });
      }, icon: Icons.add),
      const SizedBox(height: 10),
      _notice('الأمر يُحفظ في سجل محلي فقط ولا يُرسل إلى ماكينة CNC.'),
    ])),
    _panel('COMMAND HISTORY', mdiHistory.isEmpty
      ? const Text('No commands saved')
      : Column(children: mdiHistory.asMap().entries.map((e) => ListTile(
          dense: true, leading: Text('${e.key+1}'),
          title: Text(e.value, style: const TextStyle(fontFamily: 'monospace')),
          trailing: IconButton(icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() => mdiHistory.removeAt(e.key))),
        )).toList())),
  ]);

  Widget _toolpathPage() => ListView(padding: const EdgeInsets.all(12), children: [
    _panel('XY TOOLPATH', SizedBox(height: 370, child: analysis == null
      ? const Center(child: Text('افتح ملف G-code لعرض المسار'))
      : InteractiveViewer(
          minScale: .5, maxScale: 8,
          child: CustomPaint(
            size: const Size(700, 500),
            painter: ToolpathPainter(analysis!, showRapid: showRapid, showFeed: showFeed),
          )))),
    _panel('PATH EXTENTS', Column(children: [
      Row(children: [
        _metric('X MIN', analysis?.minX.toStringAsFixed(3) ?? '--'),
        _metric('X MAX', analysis?.maxX.toStringAsFixed(3) ?? '--'),
      ]),
      const SizedBox(height: 7),
      Row(children: [
        _metric('Y MIN', analysis?.minY.toStringAsFixed(3) ?? '--'),
        _metric('Y MAX', analysis?.maxY.toStringAsFixed(3) ?? '--'),
      ]),
      const SizedBox(height: 7),
      Row(children: [
        _metric('Z MIN', analysis?.minZ.toStringAsFixed(3) ?? '--'),
        _metric('Z MAX', analysis?.maxZ.toStringAsFixed(3) ?? '--'),
      ]),
    ])),
    _panel('DISPLAY FILTERS', Column(children: [
      SwitchListTile(value: showRapid, onChanged: (v) => setState(() => showRapid = v), title: const Text('Rapid moves')),
      SwitchListTile(value: showFeed, onChanged: (v) => setState(() => showFeed = v), title: const Text('Feed moves')),
    ])),
    _panel('ANALYSIS', Row(children: [
      _metric('Arcs', '${analysis?.arcCount ?? 0}'),
      _metric('Segments', '${analysis?.segments.length ?? 0}'),
      _metric('Warnings', '${analysis?.issues.length ?? 0}'),
    ])),
  ]);

  Widget _jogPage() => ListView(padding: const EdgeInsets.all(12), children: [
    _panel('JOG CONTROL', Column(children: [
      _notice('أزرار التحريك غير مفعلة قبل وجود اتصال مؤكد. لا يوجد تحريك تجريبي أو وهمي.'),
      const SizedBox(height: 16),
      _jogButton('Y+', Icons.keyboard_arrow_up),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _jogButton('X-', Icons.keyboard_arrow_left),
        const SizedBox(width: 12),
        _jogButton('X+', Icons.keyboard_arrow_right),
      ]),
      _jogButton('Y-', Icons.keyboard_arrow_down),
      const SizedBox(height: 18),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _jogButton('Z+', Icons.add),
        const SizedBox(width: 12),
        _jogButton('Z-', Icons.remove),
      ]),
      const SizedBox(height: 10),
      _jogButton('A AXIS', Icons.rotate_right),
    ])),
    _panel('JOG INCREMENT', DropdownButtonFormField<double>(
      value: jogStep,
      items: [0.001, 0.01, 0.1, 1, 10].map((v) => DropdownMenuItem(value: v, child: Text('$v $units'))).toList(),
      onChanged: (v) { if (v != null) setState(() => jogStep = v); _save(); },
    )),
    _panel('JOG SPEED', Column(children: [
      Text('${jogSpeed.round()}%'),
      Slider(value: jogSpeed, min: 1, max: 100, onChanged: (v) => setState(() => jogSpeed = v),
        onChangeEnd: (_) => _save()),
    ])),
  ]);

  Widget _jogButton(String label, IconData icon) => SizedBox(
    width: 94, height: 58, child: FilledButton.tonal(
      onPressed: null, child: Column(mainAxisAlignment: MainAxisAlignment.center,
        children: [Icon(icon), Text(label, style: const TextStyle(fontSize: 11))])));

  Future<void> _editOffset(String axis) async {
    final controller = TextEditingController(text: offsets[workSystem]![axis]!.toString());
    final value = await showDialog<double>(context: context, builder: (ctx) => AlertDialog(
      title: Text('$workSystem $axis offset'),
      content: TextField(controller: controller, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: const InputDecoration(labelText: 'Value')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(controller.text)), child: const Text('Save')),
      ],
    ));
    controller.dispose();
    if (value != null) {
      setState(() => offsets[workSystem]![axis] = value);
      await _save();
    }
  }

  Widget _offsetsPage() => ListView(padding: const EdgeInsets.all(12), children: [
    _panel('WORK COORDINATE SYSTEM', DropdownButtonFormField<String>(
      value: workSystem,
      items: ['G54','G55','G56','G57','G58','G59'].map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
      onChanged: (v) { if (v != null) setState(() => workSystem = v); _save(); },
    )),
    _panel('LOCAL OFFSET VALUES', Column(children: ['X','Y','Z'].map((a) => ListTile(
      title: Text('Axis $a'),
      subtitle: Text(offsets[workSystem]![a]!.toStringAsFixed(4)),
      trailing: IconButton(icon: const Icon(Icons.edit), onPressed: () => _editOffset(a)),
    )).toList())),
    _notice('هذه إزاحات محلية محفوظة على الهاتف، وليست قراءات أو إعدادات Mach3 الفعلية.'),
  ]);

  Future<void> _editTool(int index) async {
    final item = tools[index];
    final number = TextEditingController(text: item['number']);
    final diameter = TextEditingController(text: item['diameter']);
    final length = TextEditingController(text: item['length']);
    final description = TextEditingController(text: item['description']);
    final save = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Tool ${item['number']}'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: number, decoration: const InputDecoration(labelText: 'Tool number')),
        const SizedBox(height: 8),
        TextField(controller: diameter, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Diameter')),
        const SizedBox(height: 8),
        TextField(controller: length, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Length offset')),
        const SizedBox(height: 8),
        TextField(controller: description, decoration: const InputDecoration(labelText: 'Description')),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
      ],
    ));
    if (save == true) {
      setState(() {
        tools[index] = {'number': number.text, 'diameter': diameter.text,
          'length': length.text, 'description': description.text};
      });
      await _save();
    }
    number.dispose(); diameter.dispose(); length.dispose(); description.dispose();
  }

  Widget _toolsPage() => ListView(padding: const EdgeInsets.all(12), children: [
    _panel('TOOL TABLE', Column(children: [
      for (var i = 0; i < tools.length; i++)
        ListTile(
          leading: CircleAvatar(backgroundColor: cPanel2, child: Text(tools[i]['number'] ?? '?')),
          title: Text(tools[i]['description'] ?? ''),
          subtitle: Text('Ø ${tools[i]['diameter']}  |  L ${tools[i]['length']}'),
          trailing: IconButton(icon: const Icon(Icons.edit), onPressed: () => _editTool(i)),
        ),
      _action('ADD TOOL', () {
        setState(() => tools.add({'number': '${tools.length + 1}', 'diameter': '0', 'length': '0', 'description': 'New tool'}));
        _editTool(tools.length - 1);
      }, icon: Icons.add),
    ])),
    _notice('جدول الأدوات محلي على الهاتف. لم تتم مزامنته مع Mach3.'),
  ]);

  Widget _diagnosticsPage() {
    final signals = ['Emergency Stop', 'X Home', 'Y Home', 'Z Home', 'A Home',
      'X Limit', 'Y Limit', 'Z Limit', 'Probe', 'Spindle', 'Flood', 'Mist'];
    return ListView(padding: const EdgeInsets.all(12), children: [
      _panel('CONNECTION STATUS', Row(children: [
        const Icon(Icons.circle, color: cRed, size: 12),
        const SizedBox(width: 8),
        const Expanded(child: Text('Not connected')),
        TextButton(onPressed: null, child: const Text('Connect')),
      ])),
      _panel('INPUT SIGNALS', Column(children: signals.map((s) => ListTile(
        dense: true, leading: const Icon(Icons.circle, color: Colors.grey, size: 12),
        title: Text(s), trailing: const Text('UNKNOWN'),
      )).toList())),
      _panel('OUTPUT COMMANDS', Column(children: [
        SwitchListTile(value: spindleOn, onChanged: null, title: const Text('Spindle')),
        SwitchListTile(value: floodOn, onChanged: null, title: const Text('Flood coolant')),
        SwitchListTile(value: mistOn, onChanged: null, title: const Text('Mist coolant')),
      ])),
      _notice('لا توجد إشارات حقيقية متاحة دون الاتصال. UNKNOWN لا تعني أن الإشارة OFF.'),
      _notice('زر الطوارئ الفعلي يجب أن يظل دائرة كهربائية مستقلة عن الهاتف.', color: cRed),
    ]);
  }

  Widget _settingsPage() => ListView(padding: const EdgeInsets.all(12), children: [
    _panel('UNITS', DropdownButtonFormField<String>(
      value: units,
      items: const [
        DropdownMenuItem(value: 'mm', child: Text('Millimeters (G21)')),
        DropdownMenuItem(value: 'inch', child: Text('Inches (G20)')),
      ],
      onChanged: (v) { if (v != null) setState(() => units = v); _save(); },
    )),
    _panel('BRIDGE NETWORK CONFIGURATION', Column(children: [
      TextField(controller: ip, decoration: const InputDecoration(labelText: 'Bridge IP address', hintText: '192.168.1.100')),
      const SizedBox(height: 9),
      TextField(controller: port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'TCP port')),
      const SizedBox(height: 10),
      _action('SAVE CONFIGURATION', () async { await _save(); _message('تم حفظ الإعدادات محليًا'); },
        color: cGreen, icon: Icons.save),
      const SizedBox(height: 8),
      _notice('حقول الاتصال تحفظ الإعدادات فقط. لا يوجد اتصال TCP منفذ في هذه النسخة.'),
    ])),
    _panel('LOCAL DATA', Column(children: [
      _action('SAVE ALL LOCAL SETTINGS', () async { await _save(); _message('Saved'); }, icon: Icons.save),
      const SizedBox(height: 8),
      _action('RESET LOCAL DISPLAY OPTIONS', () async {
        setState(() { jogStep = 1; jogSpeed = 25; showRapid = true; showFeed = true; });
        await _save();
      }, icon: Icons.refresh),
    ])),
    _panel('ABOUT', const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Mach3 Mobile'),
      SizedBox(height: 5),
      Text('Android application shell and offline G-code analyzer'),
      Text('Protocol target: 1.0'),
      Text('Machine control: not connected'),
    ])),
  ]);

  Widget _currentPage() => switch (page) {
    0 => _runPage(),
    1 => _mdiPage(),
    2 => _toolpathPage(),
    3 => _jogPage(),
    4 => _offsetsPage(),
    5 => _toolsPage(),
    6 => _diagnosticsPage(),
    _ => _settingsPage(),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: cBg,
      title: Text(names[page], style: const TextStyle(fontWeight: FontWeight.bold)),
      actions: const [
        Padding(padding: EdgeInsets.only(right: 14),
          child: Center(child: Row(children: [
            Icon(Icons.circle, color: cRed, size: 9),
            SizedBox(width: 5),
            Text('OFFLINE', style: TextStyle(fontSize: 11, color: cRed, fontWeight: FontWeight.bold)),
          ]))),
      ],
    ),
    body: SafeArea(child: _currentPage()),
    bottomNavigationBar: NavigationBar(
      selectedIndex: page,
      onDestinationSelected: (i) => setState(() => page = i),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.play_circle_outline), label: 'Run'),
        NavigationDestination(icon: Icon(Icons.keyboard), label: 'MDI'),
        NavigationDestination(icon: Icon(Icons.route), label: 'Path'),
        NavigationDestination(icon: Icon(Icons.gamepad), label: 'Jog'),
        NavigationDestination(icon: Icon(Icons.tune), label: 'Offsets'),
        NavigationDestination(icon: Icon(Icons.build), label: 'Tools'),
        NavigationDestination(icon: Icon(Icons.monitor_heart), label: 'Diag'),
        NavigationDestination(icon: Icon(Icons.settings), label: 'Setup'),
      ],
    ),
  );
}

class ToolpathPainter extends CustomPainter {
  final GCodeAnalysis data;
  final bool showRapid, showFeed;
  ToolpathPainter(this.data, {required this.showRapid, required this.showFeed});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = cBg;
    canvas.drawRect(Offset.zero & size, bg);
    final grid = Paint()..color = Colors.white.withOpacity(.07)..strokeWidth = 1;
    for (var i = 0; i <= 10; i++) {
      final x = size.width * i / 10, y = size.height * i / 10;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (data.segments.isEmpty) return;

    final padding = 28.0;
    final w = math.max(data.maxX - data.minX, .001).toDouble();
    final h = math.max(data.maxY - data.minY, .001).toDouble();
    final scale = math.min((size.width - 2 * padding) / w, (size.height - 2 * padding) / h).toDouble();
    final drawW = w * scale, drawH = h * scale;
    final left = (size.width - drawW) / 2, top = (size.height - drawH) / 2;
    Offset map(Offset p) => Offset(left + (p.dx - data.minX) * scale,
      size.height - top - (p.dy - data.minY) * scale);

    final rapid = Paint()..color = cBlue..strokeWidth = 1.5..style = PaintingStyle.stroke;
    final feed = Paint()..color = cGreen..strokeWidth = 2.2..style = PaintingStyle.stroke;
    for (final s in data.segments) {
      if (s.rapid && !showRapid || !s.rapid && !showFeed) continue;
      canvas.drawLine(map(s.start), map(s.end), s.rapid ? rapid : feed);
    }
    final origin = map(const Offset(0, 0));
    canvas.drawCircle(origin, 4, Paint()..color = cAccent);
    final border = Paint()..color = Colors.white24..style = PaintingStyle.stroke;
    canvas.drawRect(Rect.fromLTWH(left, top, drawW, drawH), border);
    _legend(canvas, Offset(12, 10), cBlue, 'RAPID');
    _legend(canvas, Offset(85, 10), cGreen, 'FEED');
  }

  void _legend(Canvas canvas, Offset p, Color color, String text) {
    final paint = Paint()..color = color..strokeWidth = 3;
    canvas.drawLine(p, p + const Offset(18, 0), paint);
    final tp = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(color: Colors.white70, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, p + const Offset(23, -6));
  }

  @override
  bool shouldRepaint(covariant ToolpathPainter old) =>
      old.data != data || old.showRapid != showRapid || old.showFeed != showFeed;
}
