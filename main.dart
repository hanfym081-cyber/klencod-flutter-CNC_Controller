
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const Mach3MobileApp());

const Color bg = Color(0xFF111820);
const Color panel = Color(0xFF202B36);
const Color accent = Color(0xFFFFA62B);
const Color green = Color(0xFF35C982);

class Mach3MobileApp extends StatelessWidget {
  const Mach3MobileApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Mach3 Mobile',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: bg,
          colorScheme: const ColorScheme.dark(
            primary: green,
            secondary: accent,
          ),
          appBarTheme: const AppBarTheme(backgroundColor: bg),
        ),
        home: const Mach3Home(),
      );
}

class GMove {
  final int line;
  final Offset from;
  final Offset to;
  final bool rapid;

  const GMove(this.line, this.from, this.to, this.rapid);
}

class GProgram {
  final List<GMove> moves;
  final List<String> lines;
  final double minX, maxX, minY, maxY;
  final int motionCount;

  const GProgram(
    this.moves,
    this.lines,
    this.minX,
    this.maxX,
    this.minY,
    this.maxY,
    this.motionCount,
  );
}

class GCodeParser {
  static GProgram parse(String source) {
    final sourceLines = source.split(RegExp(r'\r?\n'));
    final moves = <GMove>[];
    final re = RegExp(
      r'([A-Z])\s*([+-]?(?:\d+\.?\d*|\.\d+))',
      caseSensitive: false,
    );

    double x = 0, y = 0, unit = 1;
    double minX = 0, maxX = 0, minY = 0, maxY = 0;
    bool absolute = true;
    int motion = 0;

    for (int i = 0; i < sourceLines.length; i++) {
      var line = sourceLines[i].replaceAll(RegExp(r'\([^)]*\)'), '');
      line = line.split(';').first.toUpperCase();

      final words = <String, List<double>>{};

      for (final match in re.allMatches(line)) {
        final key = match.group(1)!;
        final value = double.tryParse(match.group(2)!);
        if (value != null) {
          (words[key] ??= <double>[]).add(value);
        }
      }

      double? last(String key) => words[key]?.lastOrNull;

      for (final g in words['G'] ?? const <double>[]) {
        if (g == 20) unit = 25.4;
        if (g == 21) unit = 1;
        if (g == 90) absolute = true;
        if (g == 91) absolute = false;
        if (g == 0) motion = 0;
        if (g == 1 || g == 2 || g == 3) motion = g.toInt();
      }

      final oldX = x, oldY = y;

      if (last('X') != null) {
        final v = last('X')! * unit;
        x = absolute ? v : x + v;
      }

      if (last('Y') != null) {
        final v = last('Y')! * unit;
        y = absolute ? v : y + v;
      }

      if (x != oldX || y != oldY) {
        moves.add(
          GMove(i + 1, Offset(oldX, oldY), Offset(x, y), motion == 0),
        );

        minX = math.min(minX, x).toDouble();
        maxX = math.max(maxX, x).toDouble();
        minY = math.min(minY, y).toDouble();
        maxY = math.max(maxY, y).toDouble();
      }
    }

    return GProgram(
      moves,
      sourceLines,
      minX,
      maxX,
      minY,
      maxY,
      moves.length,
    );
  }
}

class Mach3Home extends StatefulWidget {
  const Mach3Home({super.key});

  @override
  State<Mach3Home> createState() => _Mach3HomeState();
}

class _Mach3HomeState extends State<Mach3Home> {
  final List<String> tabs = const [
    'Program Run',
    'MDI',
    'Toolpath',
    'Jog',
    'Offsets',
    'Tools',
    'Diagnostics',
    'Settings',
  ];

  int page = 0;
  String fileName = 'No G-code file selected';
  String source = '';
  GProgram? program;

  final mdiController = TextEditingController();
  final ipController = TextEditingController();
  final portController = TextEditingController(text: '5000');
  final mdiHistory = <String>[];

  String units = 'mm';
  String workSystem = 'G54';

  double jogIncrement = 1;
  double jogRate = 25;

  bool singleBlock = false;
  bool blockDelete = false;
  bool optionalStop = false;
  bool showRapid = true;
  bool showFeed = true;

  bool get hasProgram => program != null;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    mdiController.dispose();
    ipController.dispose();
    portController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) return;

    setState(() {
      ipController.text = prefs.getString('bridge_ip') ?? '';
      portController.text = prefs.getString('bridge_port') ?? '5000';
      units = prefs.getString('units') ?? 'mm';
      workSystem = prefs.getString('work') ?? 'G54';
      jogIncrement = prefs.getDouble('jog_increment') ?? 1;
      jogRate = prefs.getDouble('jog_rate') ?? 25;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString('bridge_ip', ipController.text.trim());
    await prefs.setString('bridge_port', portController.text.trim());
    await prefs.setString('units', units);
    await prefs.setString('work', workSystem);
    await prefs.setDouble('jog_increment', jogIncrement);
    await prefs.setDouble('jog_rate', jogRate);
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _pickGCode() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['nc', 'tap', 'gcode', 'cnc', 'txt'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final bytes = file.bytes;

    if (bytes == null) {
      _message('Could not read the selected file.');
      return;
    }

    final text = String.fromCharCodes(bytes);
    final parsed = GCodeParser.parse(text);

    setState(() {
      source = text;
      fileName = file.name;
      program = parsed;
    });

    _message(
      'Loaded for offline review: ${parsed.moves.length} XY moves.',
    );
  }

  Widget _card(String title, Widget child, {Widget? trailing}) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: accent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      );

  Widget _button(
    String label,
    VoidCallback? onPressed, {
    Color color = const Color(0xFF344553),
  }) =>
      SizedBox(
        width: double.infinity,
        height: 46,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: color,
            disabledBackgroundColor: Colors.white10,
          ),
          onPressed: onPressed,
          child: Text(label, textAlign: TextAlign.center),
        ),
      );

  Widget _metric(String label, String value) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 4,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Column(
            children: [
              Text(label, style: const TextStyle(color: accent)),
              const SizedBox(height: 5),
              Text(
                value,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _unavailable(String title, String detail) => _card(
        title,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.link_off, color: Colors.orange, size: 28),
            const SizedBox(height: 8),
            Text(detail),
            const SizedBox(height: 8),
            const Text(
              'This screen is prepared in the Android app; live machine data/control is not active in this offline stage.',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );

  Widget _programPage() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _card(
            'G-CODE FILE',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Text(
                  hasProgram
                      ? '${program!.lines.length} lines • ${program!.moves.length} XY moves'
                      : 'No file loaded',
                ),
                const SizedBox(height: 10),
                _button(
                  'OPEN G-CODE FILE',
                  _pickGCode,
                  color: green,
                ),
              ],
            ),
          ),
          _card(
            'PROGRAM REVIEW',
            Column(
              children: [
                Row(
                  children: [
                    _metric('Units', units),
                    _metric(
                      'Motion blocks',
                      '${program?.motionCount ?? 0}',
                    ),
                    _metric('Status', 'Preview'),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Cycle Start, Feed Hold and Stop are intentionally inactive until a real controller connection is implemented.',
                  style: TextStyle(color: Colors.orangeAccent),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _button(
                        'CYCLE START',
                        null,
                        color: green,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _button(
                        'FEED HOLD',
                        null,
                        color: Colors.orange.shade800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _button(
                  'STOP',
                  null,
                  color: Colors.red.shade900,
                ),
              ],
            ),
          ),
          _card(
            'G-CODE CONTENT',
            SizedBox(
              height: 270,
              child: source.isEmpty
                  ? const Center(
                      child: Text(
                        'Select a G-code file to inspect its contents.',
                      ),
                    )
                  : ListView.builder(
                      itemCount: program!.lines.length,
                      itemBuilder: (context, index) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${(index + 1).toString().padLeft(4)}  ${program!.lines[index]}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      );

  Widget _mdiPage() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _unavailable(
            'MANUAL DATA INPUT',
            'Enter G-code commands and keep a local command list. Commands are not sent to a machine.',
          ),
          _card(
            'MDI COMMAND',
            Column(
              children: [
                TextField(
                  controller: mdiController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'G0 X10 Y20 Z5',
                  ),
                ),
                const SizedBox(height: 8),
                _button(
                  'ADD TO LOCAL HISTORY',
                  () {
                    final command =
                        mdiController.text.trim().toUpperCase();

                    if (command.isEmpty) return;

                    setState(() {
                      mdiHistory.insert(0, command);
                      mdiController.clear();
                    });
                  },
                ),
              ],
            ),
          ),
          _card(
            'COMMAND HISTORY',
            mdiHistory.isEmpty
                ? const Text('No commands saved.')
                : Column(
                    children: mdiHistory
                        .map(
                          (e) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.code),
                            title: Text(
                              e,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      );

  Widget _toolpathPage() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _card(
            'TOOLPATH PREVIEW',
            SizedBox(
              height: 360,
              child: hasProgram
                  ? CustomPaint(
                      painter: ToolpathPainter(program!),
                      child: const SizedBox.expand(),
                    )
                  : const Center(
                      child: Text(
                        'Load a G-code file to build its XY preview.',
                      ),
                    ),
            ),
          ),
          _card(
            'PROGRAM BOUNDS',
            Row(
              children: [
                _metric(
                  'X MIN',
                  (program?.minX ?? 0).toStringAsFixed(3),
                ),
                _metric(
                  'X MAX',
                  (program?.maxX ?? 0).toStringAsFixed(3),
                ),
                _metric(
                  'Y MIN',
                  (program?.minY ?? 0).toStringAsFixed(3),
                ),
                _metric(
                  'Y MAX',
                  (program?.maxY ?? 0).toStringAsFixed(3),
                ),
              ],
            ),
          ),
          _card(
            'DISPLAY OPTIONS',
            Column(
              children: [
                SwitchListTile(
                  value: showRapid,
                  onChanged: (v) => setState(() => showRapid = v),
                  title: const Text('Show rapid moves'),
                ),
                SwitchListTile(
                  value: showFeed,
                  onChanged: (v) => setState(() => showFeed = v),
                  title: const Text('Show feed moves'),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _jogPage() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _unavailable(
            'MANUAL JOG',
            'The X/Y/Z controls are displayed for layout planning. They are disabled so the app cannot pretend to move a real machine.',
          ),
          _card(
            'JOG INCREMENT',
            DropdownButtonFormField<double>(
              value: jogIncrement,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
              items: const [0.001, 0.01, 0.1, 1, 10]
                  .map(
                    (v) => DropdownMenuItem(
                      value: v,
                      child: Text('$v $units'),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => jogIncrement = v);
                _saveSettings();
              },
            ),
          ),
          _card(
            'JOG RATE',
            Column(
              children: [
                Text('${jogRate.toStringAsFixed(0)}%'),
                Slider(
                  value: jogRate,
                  min: 1,
                  max: 100,
                  onChanged: (v) => setState(() => jogRate = v),
                  onChangeEnd: (_) => _saveSettings(),
                ),
                Row(
                  children: [
                    for (final axis in ['X', 'Y', 'Z'])
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: _button('$axis −', null),
                        ),
                      ),
                  ],
                ),
                Row(
                  children: [
                    for (final axis in ['X', 'Y', 'Z'])
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: _button('$axis +', null),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );

  Widget _offsetsPage() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _unavailable(
            'WORK OFFSETS',
            'G54–G59 values must eventually come from the controller. No fake coordinate values are shown.',
          ),
          _card(
            'WORK COORDINATE SYSTEM',
            DropdownButtonFormField<String>(
              value: workSystem,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
              items: const [
                'G54',
                'G55',
                'G56',
                'G57',
                'G58',
                'G59',
              ]
                  .map(
                    (e) => DropdownMenuItem(
                      value: e,
                      child: Text(e),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => workSystem = v);
                _saveSettings();
              },
            ),
          ),
          _card(
            'AXIS OFFSETS',
            const Row(
              children: [
                Expanded(child: Text('X     —')),
                Expanded(child: Text('Y     —')),
                Expanded(child: Text('Z     —')),
              ],
            ),
          ),
        ],
      );

  Widget _toolsPage() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _unavailable(
            'TOOL TABLE',
            'Tool numbers, diameters, lengths and tool changes are not invented. They will be populated from real controller data in the integration stage.',
          ),
          _card(
            'TOOL TABLE COLUMNS',
            const Text(
              'Tool number  •  Diameter  •  Length offset  •  Description',
            ),
          ),
        ],
      );

  Widget _diagnosticsPage() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _unavailable(
            'MACHINE DIAGNOSTICS',
            'Inputs, outputs, limits, home switches, probe and spindle state require live hardware readings. No simulated signal switches are provided.',
          ),
          _card(
            'SIGNALS TO BE MONITORED',
            const Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text('E-Stop')),
                Chip(label: Text('X/Y/Z Home')),
                Chip(label: Text('X/Y/Z Limits')),
                Chip(label: Text('Probe')),
                Chip(label: Text('Spindle')),
                Chip(label: Text('Flood')),
                Chip(label: Text('Mist')),
              ],
            ),
          ),
          _card(
            'SAFETY',
            const Text(
              'The physical emergency-stop circuit must remain independent of the phone and wireless connection.',
              style: TextStyle(color: Colors.orangeAccent),
            ),
          ),
        ],
      );

  Widget _settingsPage() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _card(
            'LOCAL APP SETTINGS',
            Column(
              children: [
                DropdownButtonFormField<String>(
                  value: units,
                  decoration: const InputDecoration(
                    labelText: 'Display units',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'mm',
                      child: Text('Millimeters (mm)'),
                    ),
                    DropdownMenuItem(
                      value: 'inch',
                      child: Text('Inches (inch)'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => units = v);
                    _saveSettings();
                  },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: singleBlock,
                  onChanged: (v) => setState(() => singleBlock = v),
                  title: const Text('Single Block (UI preference)'),
                ),
                SwitchListTile(
                  value: blockDelete,
                  onChanged: (v) => setState(() => blockDelete = v),
                  title: const Text('Block Delete (UI preference)'),
                ),
                SwitchListTile(
                  value: optionalStop,
                  onChanged: (v) => setState(() => optionalStop = v),
                  title: const Text('Optional Stop (UI preference)'),
                ),
              ],
            ),
          ),
          _card(
            'FUTURE CONNECTION SETTINGS',
            Column(
              children: [
                TextField(
                  controller: ipController,
                  decoration: const InputDecoration(
                    labelText: 'Bridge IP address (saved only)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'TCP port',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                _button(
                  'SAVE SETTINGS',
                  () async {
                    await _saveSettings();
                    _message(
                      'Settings saved on this phone. No connection was attempted.',
                    );
                  },
                  color: green,
                ),
              ],
            ),
          ),
          _card(
            'ABOUT THIS BUILD',
            const Text(
              'Android offline application stage. File selection, G-code text inspection, basic XY path preview and local preferences are available. Live machine control is not active.',
            ),
          ),
        ],
      );

  Widget _currentPage() {
    switch (page) {
      case 0:
        return _programPage();
      case 1:
        return _mdiPage();
      case 2:
        return _toolpathPage();
      case 3:
        return _jogPage();
      case 4:
        return _offsetsPage();
      case 5:
        return _toolsPage();
      case 6:
        return _diagnosticsPage();
      default:
        return _settingsPage();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(tabs[page]),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: Text(
                  'OFFLINE',
                  style: TextStyle(
                    color: Colors.orange.shade300,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(child: _currentPage()),
        bottomNavigationBar: NavigationBar(
          selectedIndex: page,
          onDestinationSelected: (v) => setState(() => page = v),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.play_circle_outline),
              label: 'Run',
            ),
            NavigationDestination(
              icon: Icon(Icons.keyboard),
              label: 'MDI',
            ),
            NavigationDestination(
              icon: Icon(Icons.route),
              label: 'Path',
            ),
            NavigationDestination(
              icon: Icon(Icons.gamepad),
              label: 'Jog',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune),
              label: 'Offsets',
            ),
            NavigationDestination(
              icon: Icon(Icons.build),
              label: 'Tools',
            ),
            NavigationDestination(
              icon: Icon(Icons.monitor_heart),
              label: 'Diag',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      );
}

class ToolpathPainter extends CustomPainter {
  final GProgram program;

  ToolpathPainter(this.program);

  @override
  void paint(Canvas canvas, Size size) {
    if (program.moves.isEmpty) return;

    final dx =
        math.max(0.001, program.maxX - program.minX).toDouble();
    final dy =
        math.max(0.001, program.maxY - program.minY).toDouble();

    final scale = math
        .min((size.width - 36) / dx, (size.height - 36) / dy)
        .toDouble();

    final drawW = dx * scale;
    final drawH = dy * scale;

    final left = (size.width - drawW) / 2;
    final top = (size.height - drawH) / 2;

    Offset map(Offset p) => Offset(
          left + (p.dx - program.minX) * scale,
          size.height - top - (p.dy - program.minY) * scale,
        );

    final border = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke;

    canvas.drawRect(
      Rect.fromLTWH(left, top, drawW, drawH),
      border,
    );

    for (final move in program.moves) {
      final start = map(move.from);
      final end = map(move.to);

      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..lineTo(end.dx, end.dy);

      final paint = Paint()
        ..color = move.rapid ? Colors.lightBlueAccent : green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2;

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant ToolpathPainter oldDelegate) =>
      oldDelegate.program != program;
}

extension<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
