
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Mach3App());
}

const bg = Color(0xFF15191E);
const panel = Color(0xFF222830);
const panel2 = Color(0xFF2B333D);
const accent = Color(0xFF00B8D4);
const green = Color(0xFF19C784);
const red = Color(0xFFE34B4B);
const yellow = Color(0xFFFFC247);
const muted = Color(0xFF9BA8B5);

class Mach3App extends StatelessWidget {
  const Mach3App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mach3 Mill',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          surface: panel,
        ),
        useMaterial3: true,
      ),
      home: const Mach3Home(),
    );
  }
}

enum Motion { rapid, linear, clockwise, counterClockwise }

class GCodeState {
  double x = 0, y = 0, z = 0;
  double feed = 100;
  double spindle = 0;
  bool metric = true;
  bool absolute = true;
  bool spindleOn = false;
  bool spindleReverse = false;
  int offset = 54;
  Motion motion = Motion.rapid;

  GCodeState copy() {
    final s = GCodeState();
    s.x = x;
    s.y = y;
    s.z = z;
    s.feed = feed;
    s.spindle = spindle;
    s.metric = metric;
    s.absolute = absolute;
    s.spindleOn = spindleOn;
    s.spindleReverse = spindleReverse;
    s.offset = offset;
    s.motion = motion;
    return s;
  }
}

class GCodeBlock {
  final int line;
  final String source;
  final GCodeState state;
  final bool supported;
  final String message;

  GCodeBlock({
    required this.line,
    required this.source,
    required this.state,
    required this.supported,
    required this.message,
  });
}

class GCodeParser {
  final List<GCodeBlock> blocks = [];
  final List<String> errors = [];

  GCodeState parse(String source) {
    blocks.clear();
    errors.clear();

    final state = GCodeState();
    final lines = source.split('\n');

    for (int i = 0; i < lines.length; i++) {
      final original = lines[i];
      final clean = original
          .replaceAll(RegExp(r'\([^)]*\)'), '')
          .split(';')
          .first
          .toUpperCase();

      if (clean.trim().isEmpty) continue;

      final words = RegExp(
        r'([A-Z])\s*(-?(?:\d+\.?\d*|\.\d+))',
      ).allMatches(clean).map((m) {
        return MapEntry(
          m.group(1)!,
          double.parse(m.group(2)!),
        );
      }).toList();

      final before = state.copy();
      bool supported = true;
      final notes = <String>[];

      // Modal G-codes
      for (final word in words) {
        if (word.key != 'G') continue;
        final g = word.value;

        if (g == 0) state.motion = Motion.rapid;
        else if (g == 1) state.motion = Motion.linear;
        else if (g == 2) state.motion = Motion.clockwise;
        else if (g == 3) state.motion = Motion.counterClockwise;
        else if (g == 17) {}
        else if (g == 20) state.metric = false;
        else if (g == 21) state.metric = true;
        else if (g == 90) state.absolute = true;
        else if (g == 91) state.absolute = false;
        else if (g >= 54 && g <= 59) {
          state.offset = g.toInt();
        } else if (g == 4) {
          notes.add('Dwell');
        } else {
          supported = false;
          notes.add('G${g} غير مدعوم');
        }
      }

      double scale(double value) =>
          state.metric ? value : value * 25.4;

      double? value(String key) {
        for (final w in words.reversed) {
          if (w.key == key) return scale(w.value);
        }
        return null;
      }

      for (final w in words) {
        if (w.key == 'F') {
          state.feed = scale(w.value);
        } else if (w.key == 'S') {
          state.spindle = w.value;
        } else if (w.key == 'M') {
          if (w.value == 3) {
            state.spindleOn = true;
            state.spindleReverse = false;
          } else if (w.value == 4) {
            state.spindleOn = true;
            state.spindleReverse = true;
          } else if (w.value == 5) {
            state.spindleOn = false;
          } else if (![0, 1, 2, 6, 30].contains(w.value.toInt())) {
            supported = false;
            notes.add('M${w.value} غير مدعوم');
          }
        }
      }

      final xv = value('X');
      final yv = value('Y');
      final zv = value('Z');

      if (state.absolute) {
        if (xv != null) state.x = xv;
        if (yv != null) state.y = yv;
        if (zv != null) state.z = zv;
      } else {
        if (xv != null) state.x += xv;
        if (yv != null) state.y += yv;
        if (zv != null) state.z += zv;
      }

      if (words.any((w) => w.key == 'I' || w.key == 'J')) {
        if (state.motion != Motion.clockwise &&
            state.motion != Motion.counterClockwise) {
          notes.add('I/J بدون حركة قوسية');
        }
      }

      final changed = xv != null || yv != null || zv != null;
      if (changed && state.motion == Motion.rapid) {
        notes.add('G0');
      } else if (changed && state.motion == Motion.linear) {
        notes.add('G1');
      } else if (changed) {
        notes.add('Arc');
      }

      blocks.add(GCodeBlock(
        line: i + 1,
        source: original,
        state: state.copy(),
        supported: supported,
        message: notes.join(' | '),
      ));

      if (!supported) errors.add('Line ${i + 1}: ${notes.join(', ')}');
    }

    return state;
  }
}

class Mach3Home extends StatefulWidget {
  const Mach3Home({super.key});

  @override
  State<Mach3Home> createState() => _Mach3HomeState();
}

class _Mach3HomeState extends State<Mach3Home> {
  int tab = 0;

  double mx = 0, my = 0, mz = 0;
  double wx = 0, wy = 0, wz = 0;

  double feedOverride = 100;
  double spindleOverride = 100;
  double jogStep = 1;
  double jogSpeed = 100;

  double spindleRpm = 0;
  bool spindleOn = false;
  bool spindleReverse = false;

  bool running = false;
  bool paused = false;
  bool estop = false;

  int currentLine = 0;
  int selectedOffset = 54;

  String program = '';
  String fileName = 'No file loaded';
  String ip = '192.168.1.100';
  String port = '8080';

  final parser = GCodeParser();
  List<GCodeBlock> blocks = [];
  final Map<int, List<double>> offsets = {
    54: [0, 0, 0],
    55: [0, 0, 0],
    56: [0, 0, 0],
    57: [0, 0, 0],
    58: [0, 0, 0],
    59: [0, 0, 0],
  };

  @override
  void initState() {
    super.initState();
    loadSettings();
  }

  Future<void> loadSettings() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      ip = p.getString('ip') ?? ip;
      port = p.getString('port') ?? port;
      jogStep = p.getDouble('step') ?? jogStep;
      jogSpeed = p.getDouble('jogSpeed') ?? jogSpeed;
    });
  }

  Future<void> saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('ip', ip);
    await p.setString('port', port);
    await p.setDouble('step', jogStep);
    await p.setDouble('jogSpeed', jogSpeed);
  }

  double get workX => mx - offsets[selectedOffset]![0];
  double get workY => my - offsets[selectedOffset]![1];
  double get workZ => mz - offsets[selectedOffset]![2];

  void zeroAxis(String axis) {
    final o = offsets[selectedOffset]!;
    if (axis == 'X' || axis == 'ALL') o[0] = mx;
    if (axis == 'Y' || axis == 'ALL') o[1] = my;
    if (axis == 'Z' || axis == 'ALL') o[2] = mz;
    setState(() {});
  }

  void jog(String axis, double direction) {
    if (estop || running) return;
    final amount = jogStep * direction;

    setState(() {
      if (axis == 'X') mx += amount;
      if (axis == 'Y') my += amount;
      if (axis == 'Z') mz += amount;
    });
  }

  Future<void> openFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['nc', 'tap', 'gcode', 'txt', 'ngc'],
      withData: true,
    );

    if (result == null || result.files.single.bytes == null) return;

    final file = result.files.single;
    final content = String.fromCharCodes(file.bytes!);

    setState(() {
      fileName = file.name;
      program = content;
      blocks = parser.parse(program).blocks;
      currentLine = 0;
      running = false;
      paused = false;
    });
  }

  void startProgram() {
    if (estop || blocks.isEmpty) return;
    if (currentLine >= blocks.length) currentLine = 0;

    setState(() {
      running = true;
      paused = false;
    });

    executeNext();
  }

  Future<void> executeNext() async {
    while (running && !paused && !estop &&
        currentLine < blocks.length) {
      final block = blocks[currentLine];

      await Future.delayed(const Duration(milliseconds: 250));

      if (!mounted || !running || paused || estop) return;

      setState(() {
        mx = block.state.x;
        my = block.state.y;
        mz = block.state.z;
        spindleRpm = block.state.spindle;
        spindleOn = block.state.spindleOn;
        spindleReverse = block.state.spindleReverse;
        currentLine++;
      });
    }

    if (mounted && currentLine >= blocks.length) {
      setState(() {
        running = false;
        paused = false;
      });
    }
  }

  void holdProgram() {
    setState(() {
      paused = true;
      running = false;
    });
  }

  void stopProgram() {
    setState(() {
      running = false;
      paused = false;
      currentLine = 0;
      spindleOn = false;
    });
  }

  void emergencyStop() {
    setState(() {
      estop = true;
      running = false;
      paused = false;
      spindleOn = false;
    });
  }

  void resetEmergency() {
    setState(() => estop = false);
  }

  Widget numberBox(String label, double value,
      {Color color = Colors.white}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 7),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: panel2),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 4),
          FittedBox(
            child: Text(
              value.toStringAsFixed(3),
              style: TextStyle(
                color: color,
                fontSize: 23,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget coordinates() {
    return Row(
      children: [
        Expanded(child: numberBox('X', workX, color: Colors.redAccent)),
        const SizedBox(width: 5),
        Expanded(child: numberBox('Y', workY, color: green)),
        const SizedBox(width: 5),
        Expanded(child: numberBox('Z', workZ, color: accent)),
      ],
    );
  }

  Widget machineCoordinates() {
    return Row(
      children: [
        Expanded(child: numberBox('MACHINE X', mx)),
        const SizedBox(width: 5),
        Expanded(child: numberBox('MACHINE Y', my)),
        const SizedBox(width: 5),
        Expanded(child: numberBox('MACHINE Z', mz)),
      ],
    );
  }

  Widget section(String title, Widget child) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: panel2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: accent, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget actionButton(
    String label,
    VoidCallback action, {
    Color color = panel2,
    double height = 45,
  }) {
    return SizedBox(
      height: height,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(5)),
        ),
        onPressed: action,
        child: FittedBox(
          child: Text(label,
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget sliderControl(
      String label, double value, double min, double max,
      ValueChanged<double> change) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text('${value.toStringAsFixed(0)}%',
                style: const TextStyle(color: accent)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: (v) => setState(() => change(v)),
        ),
      ],
    );
  }

  Widget programScreen() {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        section('WORK COORDINATES', coordinates()),
        section('MACHINE COORDINATES', machineCoordinates()),
        section('TOOLPATH PREVIEW', SizedBox(
          height: 180,
          child: CustomPaint(
            painter: ToolpathPainter(blocks, currentLine),
            child: const Center(
              child: Text('XY TOOLPATH',
                  style: TextStyle(color: muted, fontSize: 10)),
            ),
          ),
        )),
        section('PROGRAM CONTROL',
          Column(children: [
            Row(children: [
              Expanded(child: actionButton(
                  'CYCLE START', startProgram, color: green)),
              const SizedBox(width: 6),
              Expanded(child: actionButton(
                  'FEED HOLD', holdProgram, color: yellow)),
              const SizedBox(width: 6),
              Expanded(child: actionButton(
                  'STOP', stopProgram, color: red)),
            ]),
            const SizedBox(height: 8),
            Text('FILE: $fileName',
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            Text('LINE: $currentLine / ${blocks.length}'),
            Text(running ? 'RUNNING' :
                paused ? 'PAUSED' : 'IDLE',
                style: TextStyle(
                    color: running ? green : yellow,
                    fontWeight: FontWeight.bold)),
          ]),
        ),
        section('FEED RATE OVERRIDE',
            sliderControl('FEED', feedOverride, 0, 150,
                (v) => feedOverride = v)),
        section('SPINDLE',
          Column(children: [
            Text('${spindleRpm.toStringAsFixed(0)} RPM',
                style: const TextStyle(fontSize: 25)),
            Row(children: [
              Expanded(child: actionButton('SPINDLE CW', () {
                setState(() {
                  spindleOn = true;
                  spindleReverse = false;
                });
              }, color: green)),
              const SizedBox(width: 6),
              Expanded(child: actionButton('SPINDLE CCW', () {
                setState(() {
                  spindleOn = true;
                  spindleReverse = true;
                });
              }, color: accent)),
              const SizedBox(width: 6),
              Expanded(child: actionButton('SPINDLE STOP', () {
                setState(() => spindleOn = false);
              }, color: red)),
            ]),
            sliderControl('SPINDLE OVERRIDE', spindleOverride,
                0, 150, (v) => spindleOverride = v),
            Text(spindleOn
                ? (spindleReverse ? 'REVERSE' : 'FORWARD')
                : 'STOPPED'),
          ]),
        ),
        section('G-CODE PREVIEW', SizedBox(
          height: 220,
          child: ListView.builder(
            itemCount: blocks.length,
            itemBuilder: (context, index) {
              final b = blocks[index];
              return Container(
                color: index + 1 == currentLine
                    ? Colors.blueGrey.withOpacity(.5)
                    : Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${b.line.toString().padLeft(3)}  ${b.source}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: b.supported ? Colors.white : red,
                  ),
                ),
              );
            },
          ),
        )),
        if (parser.errors.isNotEmpty)
          section('UNSUPPORTED COMMANDS',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: parser.errors.map((e) =>
                Text(e, style: const TextStyle(color: red))).toList(),
            )),
      ],
    );
  }

  Widget jogButton(String label, String axis, double direction) {
    return SizedBox(
      width: 75,
      height: 60,
      child: ElevatedButton(
        onPressed: () => setState(() => jog(axis, direction)),
        style: ElevatedButton.styleFrom(
          backgroundColor: panel2,
          foregroundColor: Colors.white,
        ),
        child: Text(label,
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget jogScreen() {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        section('WORK COORDINATES', coordinates()),
        section('MACHINE COORDINATES', machineCoordinates()),
        section('XY JOG',
          Column(children: [
            jogButton('Y+', 'Y', 1),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                jogButton('X-', 'X', -1),
                const SizedBox(width: 20),
                jogButton('X+', 'X', 1),
              ],
            ),
            jogButton('Y-', 'Y', -1),
          ]),
        ),
        section('Z JOG',
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              jogButton('Z+', 'Z', 1),
              const SizedBox(width: 15),
              jogButton('Z-', 'Z', -1),
            ],
          ),
        ),
        section('JOG SETTINGS',
          Column(children: [
            const Text('JOG STEP'),
            Wrap(
              spacing: 6,
              children: [0.001, 0.01, 0.1, 1, 10].map((v) =>
                ChoiceChip(
                  label: Text('$v'),
                  selected: jogStep == v,
                  onSelected: (_) => setState(() => jogStep = v),
                )).toList(),
            ),
            const SizedBox(height: 8),
            Text('JOG SPEED: ${jogSpeed.toStringAsFixed(0)}%'),
            Slider(
              value: jogSpeed,
              min: 1,
              max: 100,
              onChanged: (v) => setState(() => jogSpeed = v),
            ),
          ]),
        ),
        section('ZERO WORK AXIS',
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: ['X', 'Y', 'Z', 'ALL'].map((axis) =>
              SizedBox(
                width: 75,
                child: actionButton('ZERO $axis',
                    () => setState(() => zeroAxis(axis)),
                    color: accent),
              )).toList(),
          ),
        ),
      ],
    );
  }

  Widget offsetsScreen() {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        section('MACHINE POSITION', machineCoordinates()),
        section('WORK POSITION', coordinates()),
        section('WORK OFFSET SELECT',
          Wrap(
            spacing: 6,
            children: [54, 55, 56, 57, 58, 59].map((n) =>
              ChoiceChip(
                label: Text('G$n'),
                selected: selectedOffset == n,
                onSelected: (_) => setState(() => selectedOffset = n),
              )).toList(),
          ),
        ),
        section('CURRENT OFFSET G$selectedOffset',
          Column(children: [
            numberBox('OFFSET X', offsets[selectedOffset]![0]),
            const SizedBox(height: 5),
            numberBox('OFFSET Y', offsets[selectedOffset]![1]),
            const SizedBox(height: 5),
            numberBox('OFFSET Z', offsets[selectedOffset]![2]),
          ]),
        ),
        section('ZERO WORK COORDINATES',
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: ['X', 'Y', 'Z', 'ALL'].map((axis) =>
              SizedBox(
                width: 75,
                child: actionButton('ZERO $axis',
                    () => setState(() => zeroAxis(axis)),
                    color: accent),
              )).toList(),
          ),
        ),
        section('TOOL ZERO',
          actionButton('SET TOOL ZERO (Z)',
              () => setState(() => zeroAxis('Z')),
              color: yellow),
        ),
      ],
    );
  }

  Widget filesScreen() {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        section('G-CODE FILE',
          Column(children: [
            Text(fileName,
                style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 10),
            actionButton('OPEN G-CODE FILE', openFile,
                color: accent),
            const SizedBox(height: 8),
            actionButton('CLEAR PROGRAM', () {
              setState(() {
                program = '';
                fileName = 'No file loaded';
                blocks.clear();
                currentLine = 0;
              });
            }, color: red),
          ]),
        ),
        section('PROGRAM INFORMATION',
          Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Lines: ${blocks.length}'),
              Text('Current line: $currentLine'),
              Text('Unsupported commands: ${parser.errors.length}'),
              const SizedBox(height: 10),
              const Text('PROGRAM CONTENT',
                  style: TextStyle(color: accent)),
              Container(
                height: 300,
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                color: Colors.black,
                child: SingleChildScrollView(
                  child: SelectableText(
                    program.isEmpty ? 'No program loaded' : program,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget connectionScreen() {
    final ipController = TextEditingController(text: ip);
    final portController = TextEditingController(text: port);

    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        section('MACH3 CONNECTION',
          Column(children: [
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'Windows PC IP Address',
              ),
            ),
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            const SizedBox(height: 12),
            actionButton('SAVE SETTINGS', () {
              setState(() {
                ip = ipController.text;
                port = portController.text;
              });
              saveSettings();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Settings saved')),
              );
            }, color: accent),
          ]),
        ),
        section('CONNECTION STATUS',
          const Column(children: [
            Icon(Icons.link_off, color: yellow, size: 38),
            Text('NOT CONNECTED'),
            Text('Windows communication service is not configured.',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted)),
          ]),
        ),
        section('SYSTEM INFORMATION',
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Controller: Android'),
              Text('Target: Mach3 on Windows'),
              Text('Protocol: WebSocket (planned)'),
              Text('Connection: Not active'),
            ],
          ),
        ),
      ],
    );
  }

  Widget screen() {
    switch (tab) {
      case 0: return programScreen();
      case 1: return jogScreen();
      case 2: return offsetsScreen();
      case 3: return filesScreen();
      default: return connectionScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: panel,
        title: const Text('MACH3 MILL',
            style: TextStyle(
                fontWeight: FontWeight.bold, letterSpacing: 2)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                estop ? 'ESTOP ACTIVE' : 'OFFLINE',
                style: TextStyle(
                  color: estop ? red : yellow,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(child: screen()),
        Container(
          color: Colors.black,
          padding: const EdgeInsets.all(6),
          child: Row(children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: estop ? resetEmergency : emergencyStop,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: estop ? green : red,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(estop ? 'RESET ESTOP' : 'EMERGENCY STOP',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ]),
        ),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        backgroundColor: panel,
        indicatorColor: accent.withOpacity(.2),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline),
            label: 'PROGRAM',
          ),
          NavigationDestination(
            icon: Icon(Icons.gamepad),
            label: 'JOG',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune),
            label: 'OFFSETS',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_open),
            label: 'FILES',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_ethernet),
            label: 'CONNECT',
          ),
        ],
      ),
    );
  }
}

class ToolpathPainter extends CustomPainter {
  final List<GCodeBlock> blocks;
  final int currentLine;

  ToolpathPainter(this.blocks, this.currentLine);

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = Colors.black;
    canvas.drawRect(Offset.zero & size, bgPaint);

    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = .5;

    for (double x = 0; x < size.width; x += 20) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y < size.height; y += 20) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    if (blocks.isEmpty) return;

    final xs = blocks.map((b) => b.state.x);
    final ys = blocks.map((b) => b.state.y);

    final minX = xs.reduce(math.min);
    final maxX = xs.reduce(math.max);
    final minY = ys.reduce(math.min);
    final maxY = ys.reduce(math.max);

    final dx = (maxX - minX).abs() < .001 ? 1.0 : maxX - minX;
    final dy = (maxY - minY).abs() < .001 ? 1.0 : maxY - minY;

    Offset point(GCodeState s) => Offset(
      12 + (s.x - minX) / dx * (size.width - 24),
      size.height - 12 - (s.y - minY) / dy * (size.height - 24),
    );

    final path = Path();
    bool first = true;
    Offset previous = Offset.zero;

    for (final block in blocks) {
      final p = point(block.state);
      if (first) {
        path.moveTo(p.dx, p.dy);
        first = false;
      } else {
        path.lineTo(p.dx, p.dy);
      }
      previous = p;
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = accent
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    if (currentLine > 0 && currentLine <= blocks.length) {
      final p = point(blocks[currentLine - 1].state);
      canvas.drawCircle(
        p,
        5,
        Paint()..color = yellow,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ToolpathPainter oldDelegate) =>
      oldDelegate.blocks != blocks ||
      oldDelegate.currentLine != currentLine;
}