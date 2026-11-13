
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

void main() => runApp(const Mach3Remote());

const bg = Color(0xFF171C22);
const panel = Color(0xFF252D36);
const green = Color(0xFF36D17C);
const orange = Color(0xFFFFA62B);
const red = Color(0xFFE53935);

class Mach3Remote extends StatelessWidget {
  const Mach3Remote({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mach3 Remote',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(primary: green),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

// حركة واحدة مستخرجة من ملف G-code
class ToolMove {
  final int lineIndex;
  final Offset start;
  final Offset end;
  final bool rapid;
  final List<Offset> points;

  const ToolMove({
    required this.lineIndex,
    required this.start,
    required this.end,
    required this.rapid,
    required this.points,
  });
}

// نتيجة تحليل ملف G-code
class ToolpathData {
  final List<ToolMove> moves;
  final List<Offset> allPoints;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  const ToolpathData({
    required this.moves,
    required this.allPoints,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });
}

class GCodeParser {
  static ToolpathData parse(List<String> lines) {
    double x = 0, y = 0, z = 0;
    double unit = 1;
    bool absolute = true;
    int motion = 0;

    final moves = <ToolMove>[];
    final allPoints = <Offset>[Offset.zero];

    double minX = 0, maxX = 0;
    double minY = 0, maxY = 0;

    void addPoint(Offset p) {
      allPoints.add(p);
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }

    final numberPattern = RegExp(
      r'([A-Z])\s*(-?\d+(?:\.\d*)?|-?\.\d+)',
      caseSensitive: false,
    );

    for (int lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      String source = lines[lineIndex]
          .replaceAll(RegExp(r'\([^)]*\)'), '')
          .split(';')
          .first
          .toUpperCase();

      final words = <String, double>{};

      for (final match in numberPattern.allMatches(source)) {
        final letter = match.group(1)!;
        final value = double.tryParse(match.group(2)!);
        if (value != null) words[letter] = value;
      }

      // وحدات القياس
      if (words['G'] == 20) unit = 25.4;
      if (words['G'] == 21) unit = 1;

      // إحداثيات مطلقة أو نسبية
      if (RegExp(r'G\s*90(?:\D|$)').hasMatch(source)) {
        absolute = true;
      }
      if (RegExp(r'G\s*91(?:\D|$)').hasMatch(source)) {
        absolute = false;
      }

      // نوع الحركة
      final gCodes = RegExp(r'G\s*(0|1|2|3)\b')
          .allMatches(source);

      for (final match in gCodes) {
        motion = int.parse(match.group(1)!);
      }

      final hasAxis = words.containsKey('X') ||
          words.containsKey('Y') ||
          words.containsKey('Z');

      if (!hasAxis) continue;
      if (motion != 0 && motion != 1 &&
          motion != 2 && motion != 3) {
        continue;
      }

      final oldX = x;
      final oldY = y;
      final oldZ = z;

      if (words.containsKey('X')) {
        final v = words['X']! * unit;
        x = absolute ? v : x + v;
      }

      if (words.containsKey('Y')) {
        final v = words['Y']! * unit;
        y = absolute ? v : y + v;
      }

      if (words.containsKey('Z')) {
        final v = words['Z']! * unit;
        z = absolute ? v : z + v;
      }

      final start = Offset(oldX, oldY);
      final end = Offset(x, y);

      // لا نرسم حركة لا تغيّر موضع XY
      if ((end - start).distance < 0.0000001) {
        continue;
      }

      final points = <Offset>[start];

      if (motion == 2 || motion == 3) {
        // G2/G3 باستخدام I و J بالنسبة لنقطة البداية
        final i = (words['I'] ?? 0) * unit;
        final j = (words['J'] ?? 0) * unit;

        final center = Offset(oldX + i, oldY + j);
        final radius = (start - center).distance;

        if (radius > 0.000001 && (words.containsKey('I') ||
            words.containsKey('J'))) {
          final startAngle = math.atan2(
            start.dy - center.dy,
            start.dx - center.dx,
          );

          final endAngle = math.atan2(
            end.dy - center.dy,
            end.dx - center.dx,
          );

          double sweep = endAngle - startAngle;

          if (motion == 2) {
            while (sweep >= 0) {
              sweep -= 2 * math.pi;
            }
          } else {
            while (sweep <= 0) {
              sweep += 2 * math.pi;
            }
          }

          final segments = math.max(
            12,
            (sweep.abs() * radius / 2).ceil(),
          );

          for (int n = 1; n <= segments; n++) {
            final angle = startAngle + sweep * n / segments;
            points.add(
              Offset(
                center.dx + radius * math.cos(angle),
                center.dy + radius * math.sin(angle),
              ),
            );
          }

          points[points.length - 1] = end;
        } else {
          points.add(end);
        }
      } else {
        points.add(end);
      }

      final move = ToolMove(
        lineIndex: lineIndex,
        start: start,
        end: end,
        rapid: motion == 0,
        points: points,
      );

      moves.add(move);

      for (final p in points) {
        addPoint(p);
      }
    }

    return ToolpathData(
      moves: moves,
      allPoints: allPoints,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int page = 0;

  String ip = '192.168.1.100';
  String port = '8765';

  bool connected = false;
  bool programRunning = false;
  bool feedHold = false;
  bool emergency = false;
  bool spindleOn = false;

  String selectedAxis = 'X';
  String jogStep = '1.0';
  String workCoordinate = 'G54';

  String fileName = 'لم يتم اختيار ملف';
  String fileInfo = '';
  String fileContent = '';

  List<String> gcodeLines = [];
  int currentLine = 0;

  double machineX = 0;
  double machineY = 0;
  double machineZ = 0;

  double workX = 0;
  double workY = 0;
  double workZ = 0;

  double jogSpeed = 50;
  double feedOverride = 100;
  double spindleOverride = 100;

  double programmedFeed = 0;
  double programmedRpm = 0;

  double get actualFeed => programmedFeed * feedOverride / 100;

  double get actualRpm =>
      spindleOn && !emergency
          ? programmedRpm * spindleOverride / 100
          : 0;

  Timer? programTimer;

  final ScrollController lineScrollController = ScrollController();

  ToolpathData? toolpath;
  int executedMoves = 0;
  Offset toolPosition = Offset.zero;

  final Map<String, Map<String, double>> offsets = {
    for (final code in ['G54', 'G55', 'G56', 'G57', 'G58', 'G59'])
      code: {'X': 0, 'Y': 0, 'Z': 0},
  };

  final List<String> pageTitles = [
    'PROGRAM RUN',
    'MANUAL JOG',
    'WORK OFFSETS',
    'FILES',
    'CONNECTION',
  ];

  @override
  void initState() {
    super.initState();
    loadSettings();
    updateWorkCoordinates();
  }

  @override
  void dispose() {
    programTimer?.cancel();
    lineScrollController.dispose();
    super.dispose();
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    setState(() {
      ip = prefs.getString('ip') ?? ip;
      port = prefs.getString('port') ?? port;
    });
  }

  Future<void> saveSettings(String newIp, String newPort) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ip', newIp);
    await prefs.setString('port', newPort);

    if (!mounted) return;

    setState(() {
      ip = newIp;
      port = newPort;
    });

    notify('تم حفظ إعدادات الاتصال');
  }

  void notify(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textAlign: TextAlign.center),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void updateWorkCoordinates() {
    final offset = offsets[workCoordinate]!;

    workX = machineX - offset['X']!;
    workY = machineY - offset['Y']!;
    workZ = machineZ - offset['Z']!;
  }

  void moveAxis(String axis, double direction) {
    if (emergency) {
      notify('ألغِ حالة الطوارئ أولاً');
      return;
    }

    if (programRunning && !feedHold) {
      notify('أوقف البرنامج قبل الحركة اليدوية');
      return;
    }

    final distance = double.parse(jogStep) * direction;

    setState(() {
      if (axis == 'X') {
        machineX += distance;
      } else if (axis == 'Y') {
        machineY += distance;
      } else {
        machineZ += distance;
      }

      updateWorkCoordinates();
    });
  }

  void zeroAxis(String axis) {
    if (emergency) return;

    setState(() {
      offsets[workCoordinate]![axis] =
          axis == 'X'
              ? machineX
              : axis == 'Y'
                  ? machineY
                  : machineZ;

      updateWorkCoordinates();
    });

    notify('تم تصفير $axis في $workCoordinate');
  }

  void zeroAll() {
    if (emergency) return;

    setState(() {
      offsets[workCoordinate]!['X'] = machineX;
      offsets[workCoordinate]!['Y'] = machineY;
      offsets[workCoordinate]!['Z'] = machineZ;
      updateWorkCoordinates();
    });

    notify('تم تصفير جميع المحاور في $workCoordinate');
  }

  void toolZero() {
    if (emergency) return;

    setState(() {
      offsets[workCoordinate]!['Z'] = machineZ;
      updateWorkCoordinates();
    });

    notify('تم ضبط صفر الأداة تجريبياً');
  }

  void changeWorkCoordinate(String? value) {
    if (value == null) return;

    setState(() {
      workCoordinate = value;
      updateWorkCoordinates();
    });

    notify('تم اختيار $value');
  }

  Future<void> chooseFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['nc', 'tap', 'gcode', 'txt', 'cnc'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final selected = result.files.first;
      final bytes = selected.bytes;

      if (bytes == null) {
        notify('تعذرت قراءة الملف');
        return;
      }

      final content = String.fromCharCodes(bytes);
      final lines = content
          .split(RegExp(r'\r?\n'))
          .where((line) => line.trim().isNotEmpty)
          .toList();

      final parsed = GCodeParser.parse(lines);

      setState(() {
        fileName = selected.name;
        fileInfo =
            'الحجم: ${(selected.size / 1024).toStringAsFixed(1)} KB';
        fileContent = content;
        gcodeLines = lines;

        currentLine = 0;
        executedMoves = 0;

        toolpath = parsed;
        toolPosition = parsed.allPoints.isNotEmpty
            ? parsed.allPoints.first
            : Offset.zero;

        programmedFeed = 0;
        programmedRpm = 0;
        spindleOn = false;

        programRunning = false;
        feedHold = false;
      });

      programTimer?.cancel();

      if (lineScrollController.hasClients) {
        lineScrollController.jumpTo(0);
      }

      if (parsed.moves.isEmpty) {
        notify('تم تحميل الملف، لكن لم يتم العثور على حركات XY');
      } else {
        notify('تم تحميل المسار: ${parsed.moves.length} حركة');
      }
    } catch (e) {
      notify('حدث خطأ أثناء فتح الملف: $e');
    }
  }

  double? readAxisValue(String line, String axis) {
    final cleanLine = line
        .replaceAll(RegExp(r'\([^)]*\)'), '')
        .split(';')
        .first;

    final match = RegExp(
      '(?:^|[^A-Z])$axis\\s*(-?\\d+(?:\\.\\d+)?)',
      caseSensitive: false,
    ).firstMatch(cleanLine);

    if (match == null) return null;
    return double.tryParse(match.group(1)!);
  }

  int? readMCode(String line) {
    final cleanLine = line
        .replaceAll(RegExp(r'\([^)]*\)'), '')
        .split(';')
        .first;

    final match = RegExp(
      r'M\s*(3|4|5)\b',
      caseSensitive: false,
    ).firstMatch(cleanLine);

    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  void executeSimulationLine(String line) {
    final f = readAxisValue(line, 'F');
    final s = readAxisValue(line, 'S');
    final m = readMCode(line);

    // موضع الأداة يُؤخذ من الحركات المحللة مسبقاً
    final moves = toolpath?.moves ?? [];

    int completed = 0;

    for (final move in moves) {
      if (move.lineIndex < currentLine) {
        completed++;
      } else {
        break;
      }
    }

    setState(() {
      if (f != null) programmedFeed = f;
      if (s != null) programmedRpm = s;

      if (m == 3 || m == 4) {
        spindleOn = true;
      } else if (m == 5) {
        spindleOn = false;
      }

      executedMoves = completed;

      if (completed > 0 && completed <= moves.length) {
        final move = moves[completed - 1];
        toolPosition = move.end;
        machineX = move.end.dx;
        machineY = move.end.dy;
      }

      updateWorkCoordinates();
    });
  }

  void keepCurrentLineVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !lineScrollController.hasClients) return;

      const lineHeight = 22.0;
      const visibleLinesAbove = 4;

      final activeIndex = currentLine - 1;
      if (activeIndex < 0) return;

      final targetOffset =
          (activeIndex - visibleLinesAbove) * lineHeight;

      final position = lineScrollController.position;

      final safeOffset = targetOffset
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();

      lineScrollController.animateTo(
        safeOffset,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void startProgram() {
    if (emergency) {
      notify('ألغِ حالة الطوارئ أولاً');
      return;
    }

    if (gcodeLines.isEmpty) {
      notify('اختر ملف G-code أولاً');
      return;
    }

    if (programRunning && feedHold) {
      setState(() {
        feedHold = false;
      });

      notify('استئناف المحاكاة');
      return;
    }

    if (currentLine >= gcodeLines.length) {
      setState(() {
        currentLine = 0;
        executedMoves = 0;
        toolPosition = toolpath?.allPoints.first ?? Offset.zero;
        programmedFeed = 0;
        programmedRpm = 0;
        spindleOn = false;
      });
    }

    programTimer?.cancel();

    setState(() {
      programRunning = true;
      feedHold = false;
    });

    programTimer = Timer.periodic(
      Duration(
        milliseconds: math.max(
          100,
          (1000 / (jogSpeed / 50 + 1)).round(),
        ),
      ),
      (timer) {
        if (!mounted || !programRunning || feedHold || emergency) {
          return;
        }

        if (currentLine >= gcodeLines.length) {
          timer.cancel();

          setState(() {
            programRunning = false;
            currentLine = gcodeLines.length;
            executedMoves = toolpath?.moves.length ?? 0;
          });

          notify('اكتملت محاكاة البرنامج');
          return;
        }

        final line = gcodeLines[currentLine];

        setState(() {
          currentLine++;
        });

        executeSimulationLine(line);
        keepCurrentLineVisible();
      },
    );

    notify('بدأت محاكاة البرنامج');
  }

  void pauseProgram() {
    if (!programRunning) {
      notify('لا يوجد برنامج يعمل');
      return;
    }

    setState(() {
      feedHold = true;
    });

    notify('تم إيقاف المحاكاة مؤقتاً');
  }

  void stopProgram() {
    programTimer?.cancel();

    setState(() {
      programRunning = false;
      feedHold = false;
      currentLine = 0;
      executedMoves = 0;
      spindleOn = false;
      toolPosition = toolpath?.allPoints.first ?? Offset.zero;
    });

    if (lineScrollController.hasClients) {
      lineScrollController.jumpTo(0);
    }

    notify('تم إيقاف المحاكاة');
  }

  void emergencyStop() {
    programTimer?.cancel();

    setState(() {
      emergency = true;
      programRunning = false;
      feedHold = false;
      spindleOn = false;
    });

    notify('تم إيقاف المحاكاة - ليس إيقافاً حقيقياً للماكينة');
  }

  void resetEmergency() {
    setState(() {
      emergency = false;
    });

    notify('تم إلغاء حالة الطوارئ التجريبية');
  }

  void toggleConnection() {
    setState(() {
      connected = !connected;
    });

    notify(
      connected
          ? 'تم تفعيل حالة الاتصال التجريبية'
          : 'تم فصل حالة الاتصال التجريبية',
    );
  }

  Future<void> showSettings() async {
    final ipController = TextEditingController(text: ip);
    final portController = TextEditingController(text: port);

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: panel,
        title: const Text('إعدادات الاتصال'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'عنوان IP الكمبيوتر',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newIp = ipController.text.trim();
              final newPort = portController.text.trim();
              final parsedPort = int.tryParse(newPort);

              if (newIp.isEmpty ||
                  parsedPort == null ||
                  parsedPort < 1 ||
                  parsedPort > 65535) {
                notify('راجع عنوان IP والمنفذ');
                return;
              }

              await saveSettings(newIp, newPort);

              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );

    ipController.dispose();
    portController.dispose();
  }

  Widget panelBox({
    required String title,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: green,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget actionButton(
    String text,
    VoidCallback action, {
    Color color = const Color(0xFF344452),
    IconData icon = Icons.circle,
  }) {
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: action,
        icon: Icon(icon, size: 17),
        label: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
          ),
        ),
      ),
    );
  }

  Widget valueBox(String title, double value) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF11161C),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          children: [
            Text(
              title,
              style: const TextStyle(
                color: orange,
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 7),
            FittedBox(
              child: Text(
                value.toStringAsFixed(4),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: green,
                  fontSize: 19,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget coordinatesPanel({
    required String title,
    required double x,
    required double y,
    required double z,
  }) {
    return panelBox(
      title: title,
      child: Row(
        children: [
          valueBox('X', x),
          valueBox('Y', y),
          valueBox('Z', z),
        ],
      ),
    );
  }

  Widget zeroButtons() {
    return panelBox(
      title: 'ZERO AXIS',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: actionButton('ZERO X', () => zeroAxis('X'))),
              const SizedBox(width: 6),
              Expanded(child: actionButton('ZERO Y', () => zeroAxis('Y'))),
              const SizedBox(width: 6),
              Expanded(child: actionButton('ZERO Z', () => zeroAxis('Z'))),
            ],
          ),
          const SizedBox(height: 10),
          actionButton(
            'ZERO ALL',
            zeroAll,
            color: const Color(0xFF167A42),
          ),
        ],
      ),
    );
  }

  Widget buildProgramScreen() {
    final progress = gcodeLines.isEmpty
        ? 0.0
        : (currentLine / gcodeLines.length).clamp(0.0, 1.0);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        panelBox(
          title: 'PROGRAM FILE',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fileName),
              const SizedBox(height: 5),
              Text(fileInfo, style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 12),
              actionButton(
                'فتح ملف G-code',
                chooseFile,
                icon: Icons.folder_open,
              ),
            ],
          ),
        ),

        panelBox(
          title: 'TOOLPATH DISPLAY',
          child: Column(
            children: [
              SizedBox(
                height: 230,
                width: double.infinity,
                child: CustomPaint(
                  painter: ToolpathPainter(
                    data: toolpath,
                    executedMoves: executedMoves,
                    toolPosition: toolPosition,
                  ),
                  child: toolpath == null
                      ? const Center(
                          child: Text(
                            'اختر ملف G-code لعرض المسار',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 16,
                children: const [
                  LegendDot(color: Colors.white54, text: 'المسار الكامل'),
                  LegendDot(color: green, text: 'تم تنفيذه'),
                  LegendDot(color: orange, text: 'موضع الأداة'),
                  LegendDot(color: Colors.blueAccent, text: 'حركة G0'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'الحركات: $executedMoves / ${toolpath?.moves.length ?? 0}',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),

        coordinatesPanel(
          title: 'WORK COORDINATES',
          x: workX,
          y: workY,
          z: workZ,
        ),

        panelBox(
          title: 'PROGRAM RUN',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: actionButton(
                      programRunning && feedHold
                          ? 'RESUME'
                          : 'CYCLE START',
                      startProgram,
                      color: const Color(0xFF167A42),
                      icon: Icons.play_arrow,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: actionButton(
                      'FEED HOLD',
                      pauseProgram,
                      color: const Color(0xFFAA7621),
                      icon: Icons.pause,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              actionButton(
                'STOP',
                stopProgram,
                color: Colors.red.shade900,
                icon: Icons.stop,
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              Text(
                'السطر: $currentLine / ${gcodeLines.length}',
                style: const TextStyle(color: Colors.white70),
              ),
              Text('${(progress * 100).toStringAsFixed(1)}%'),
            ],
          ),
        ),

        panelBox(
          title: 'G-CODE LINES',
          child: Container(
            height: 220,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF10161D),
              borderRadius: BorderRadius.circular(8),
            ),
            child: gcodeLines.isEmpty
                ? const Center(child: Text('لا يوجد ملف محمّل'))
                : ListView.builder(
                    controller: lineScrollController,
                    itemCount: gcodeLines.length,
                    itemExtent: 22,
                    itemBuilder: (context, index) {
                      final active = index == currentLine - 1;

                      return Container(
                        alignment: Alignment.centerLeft,
                        color: active
                            ? green.withOpacity(0.25)
                            : Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: Text(
                          '${index + 1}: ${gcodeLines[index]}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: active
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: active ? green : Colors.white70,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),

        panelBox(
          title: 'FEED RATE',
          child: Column(
            children: [
              const Text(
                'PROGRAMMED FEED (F)',
                style: TextStyle(color: Colors.white54),
              ),
              Text(
                '${programmedFeed.toStringAsFixed(1)} mm/min',
                style: const TextStyle(
                  fontSize: 23,
                  color: orange,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'ACTUAL FEED (SIMULATED)',
                style: TextStyle(color: Colors.white54),
              ),
              Text(
                '${actualFeed.toStringAsFixed(1)} mm/min',
                style: const TextStyle(
                  fontSize: 27,
                  color: green,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Divider(color: Colors.white24),
              Text(
                'FEED OVERRIDE: ${feedOverride.toInt()}%',
                style: const TextStyle(fontSize: 18, color: green),
              ),
              Slider(
                value: feedOverride,
                min: 10,
                max: 150,
                onChanged: (v) => setState(() => feedOverride = v),
              ),
            ],
          ),
        ),

        panelBox(
          title: 'SPINDLE SPEED',
          child: Column(
            children: [
              const Text(
                'PROGRAMMED RPM (S)',
                style: TextStyle(color: Colors.white54),
              ),
              Text(
                '${programmedRpm.toInt()} RPM',
                style: const TextStyle(
                  fontSize: 23,
                  color: orange,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'ACTUAL RPM (SIMULATED)',
                style: TextStyle(color: Colors.white54),
              ),
              Text(
                '${actualRpm.toInt()} RPM',
                style: const TextStyle(
                  fontSize: 27,
                  color: green,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Divider(color: Colors.white24),
              Row(
                children: [
                  Expanded(
                    child: actionButton(
                      'SPINDLE ON',
                      () {
                        if (emergency) return;

                        setState(() {
                          if (programmedRpm == 0) {
                            programmedRpm = 3000;
                          }
                          spindleOn = true;
                        });
                      },
                      color: const Color(0xFF167A42),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: actionButton(
                      'SPINDLE OFF',
                      () {
                        setState(() {
                          spindleOn = false;
                        });
                      },
                      color: Colors.red.shade900,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        panelBox(
          title: 'SPINDLE OVERRIDE',
          child: Column(
            children: [
              Text(
                '${spindleOverride.toInt()}%',
                style: const TextStyle(fontSize: 24, color: green),
              ),
              Slider(
                value: spindleOverride,
                min: 50,
                max: 150,
                onChanged: (v) => setState(() => spindleOverride = v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildJogScreen() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        coordinatesPanel(
          title: 'MACHINE COORDINATES',
          x: machineX,
          y: machineY,
          z: machineZ,
        ),
        coordinatesPanel(
          title: 'WORK COORDINATES - $workCoordinate',
          x: workX,
          y: workY,
          z: workZ,
        ),
        panelBox(
          title: 'SELECT AXIS',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: ['X', 'Y', 'Z'].map((axis) {
              return ChoiceChip(
                label: Text(axis, style: const TextStyle(fontSize: 18)),
                selected: selectedAxis == axis,
                onSelected: (_) => setState(() => selectedAxis = axis),
              );
            }).toList(),
          ),
        ),
        panelBox(
          title: 'JOG STEP',
          child: DropdownButtonFormField<String>(
            value: jogStep,
            decoration: const InputDecoration(
              labelText: 'مسافة الحركة',
              border: OutlineInputBorder(),
            ),
            items: ['0.01', '0.1', '1.0', '10.0'].map((v) {
              return DropdownMenuItem(
                value: v,
                child: Text('$v mm'),
              );
            }).toList(),
            onChanged: (v) {
              if (v != null) setState(() => jogStep = v);
            },
          ),
        ),
        panelBox(
          title: 'JOG CONTROL - $selectedAxis',
          child: Row(
            children: [
              Expanded(
                child: actionButton(
                  'NEGATIVE  −',
                  () => moveAxis(selectedAxis, -1),
                  icon: Icons.remove,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: actionButton(
                  'POSITIVE  +',
                  () => moveAxis(selectedAxis, 1),
                  color: const Color(0xFF167A42),
                  icon: Icons.add,
                ),
              ),
            ],
          ),
        ),
        panelBox(
          title: 'JOG SPEED',
          child: Column(
            children: [
              Text(
                '${jogSpeed.toInt()}%',
                style: const TextStyle(fontSize: 22, color: green),
              ),
              Slider(
                value: jogSpeed,
                min: 1,
                max: 100,
                onChanged: (v) => setState(() => jogSpeed = v),
              ),
            ],
          ),
        ),
        zeroButtons(),
      ],
    );
  }

  Widget buildOffsetsScreen() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        coordinatesPanel(
          title: 'MACHINE COORDINATES',
          x: machineX,
          y: machineY,
          z: machineZ,
        ),
        coordinatesPanel(
          title: 'WORK COORDINATES',
          x: workX,
          y: workY,
          z: workZ,
        ),
        panelBox(
          title: 'WORK OFFSET',
          child: DropdownButtonFormField<String>(
            value: workCoordinate,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
            ),
            items: ['G54', 'G55', 'G56', 'G57', 'G58', 'G59']
                .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                .toList(),
            onChanged: changeWorkCoordinate,
          ),
        ),
        panelBox(
          title: 'CURRENT OFFSET VALUES',
          child: Row(
            children: [
              valueBox('X', offsets[workCoordinate]!['X']!),
              valueBox('Y', offsets[workCoordinate]!['Y']!),
              valueBox('Z', offsets[workCoordinate]!['Z']!),
            ],
          ),
        ),
        zeroButtons(),
        panelBox(
          title: 'TOOL OFFSET',
          child: actionButton(
            'TOOL ZERO',
            toolZero,
            icon: Icons.build,
          ),
        ),
      ],
    );
  }

  Widget buildFilesScreen() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        panelBox(
          title: 'G-CODE FILES',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.insert_drive_file,
                size: 45,
                color: orange,
              ),
              const SizedBox(height: 10),
              Text(fileName),
              Text(fileInfo, style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 15),
              actionButton(
                'اختيار ملف من الموبايل',
                chooseFile,
                icon: Icons.folder_open,
              ),
              const SizedBox(height: 10),
              actionButton(
                'إرسال الملف إلى الكمبيوتر',
                () {
                  if (fileContent.isEmpty) {
                    notify('اختر ملفاً أولاً');
                  } else {
                    notify('المعاينة جاهزة - الإرسال الحقيقي غير مربوط');
                  }
                },
                icon: Icons.upload,
              ),
              const SizedBox(height: 10),
              actionButton(
                'تحميل الملف داخل Mach3',
                () {
                  if (fileContent.isEmpty) {
                    notify('اختر ملفاً أولاً');
                  } else {
                    setState(() {
                      page = 0;
                    });
                    notify('تم تجهيز الملف للمحاكاة');
                  }
                },
                icon: Icons.file_download,
              ),
            ],
          ),
        ),
        panelBox(
          title: 'FILE CONTENT',
          child: SizedBox(
            height: 300,
            child: fileContent.isEmpty
                ? const Center(child: Text('اختر ملف G-code'))
                : SingleChildScrollView(
                    child: SelectableText(
                      fileContent,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: green,
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget buildConnectionScreen() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        panelBox(
          title: 'LOCAL NETWORK',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('عنوان الكمبيوتر'),
              Text(
                ip,
                style: const TextStyle(color: green, fontSize: 19),
              ),
              const SizedBox(height: 12),
              const Text('Port'),
              Text(
                port,
                style: const TextStyle(color: green, fontSize: 19),
              ),
              const SizedBox(height: 15),
              actionButton(
                'تعديل إعدادات الاتصال',
                showSettings,
                icon: Icons.settings,
              ),
            ],
          ),
        ),
        panelBox(
          title: 'CONNECTION STATUS',
          child: Column(
            children: [
              Icon(
                connected ? Icons.wifi : Icons.wifi_off,
                size: 50,
                color: connected ? green : red,
              ),
              const SizedBox(height: 10),
              Text(
                connected ? 'متصل - وضع تجريبي' : 'غير متصل',
                style: TextStyle(
                  color: connected ? green : red,
                  fontSize: 19,
                ),
              ),
              const SizedBox(height: 15),
              actionButton(
                connected
                    ? 'فصل الاتصال التجريبي'
                    : 'تفعيل الاتصال التجريبي',
                toggleConnection,
                icon: Icons.wifi,
              ),
            ],
          ),
        ),
        panelBox(
          title: 'SYSTEM INFORMATION',
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Controller: Mach3 Mill'),
              SizedBox(height: 8),
              Text('Network: Wi-Fi'),
              SizedBox(height: 8),
              Text('Mode: Local Simulation'),
              SizedBox(height: 8),
              Text('Protocol: WebSocket - غير مربوط حالياً'),
            ],
          ),
        ),
      ],
    );
  }

  Widget currentPage() {
    switch (page) {
      case 0:
        return buildProgramScreen();
      case 1:
        return buildJogScreen();
      case 2:
        return buildOffsetsScreen();
      case 3:
        return buildFilesScreen();
      default:
        return buildConnectionScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF202832),
        title: Text(
          pageTitles[page],
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 17,
          ),
        ),
        actions: [
          ElevatedButton.icon(
            onPressed: emergency ? resetEmergency : emergencyStop,
            icon: Icon(
              emergency ? Icons.lock_open : Icons.warning,
              size: 17,
            ),
            label: Text(emergency ? 'RESET' : 'E-STOP'),
            style: ElevatedButton.styleFrom(
              backgroundColor: emergency ? green : red,
              foregroundColor: Colors.white,
            ),
          ),
          IconButton(
            onPressed: showSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: SafeArea(child: currentPage()),
      bottomNavigationBar: NavigationBar(
        selectedIndex: page,
        onDestinationSelected: (index) => setState(() => page = index),
        backgroundColor: const Color(0xFF202832),
        indicatorColor: green.withOpacity(0.18),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline),
            label: 'البرنامج',
          ),
          NavigationDestination(
            icon: Icon(Icons.gamepad),
            label: 'الحركة اليدوية',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune),
            label: 'الأوفست',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder),
            label: 'الملفات',
          ),
          NavigationDestination(
            icon: Icon(Icons.wifi),
            label: 'الاتصال',
          ),
        ],
      ),
    );
  }
}

class LegendDot extends StatelessWidget {
  final Color color;
  final String text;

  const LegendDot({
    super.key,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}

class ToolpathPainter extends CustomPainter {
  final ToolpathData? data;
  final int executedMoves;
  final Offset toolPosition;

  const ToolpathPainter({
    required this.data,
    required this.executedMoves,
    required this.toolPosition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.07)
      ..strokeWidth = 0.6;

    for (double i = 0; i < size.width; i += 20) {
      canvas.drawLine(
        Offset(i, 0),
        Offset(i, size.height),
        gridPaint,
      );
    }

    for (double i = 0; i < size.height; i += 20) {
      canvas.drawLine(
        Offset(0, i),
        Offset(size.width, i),
        gridPaint,
      );
    }

    final result = data;

    if (result == null || result.moves.isEmpty) {
      return;
    }

    const margin = 22.0;

    final availableWidth = math.max(1.0, size.width - margin * 2);
    final availableHeight = math.max(1.0, size.height - margin * 2);

    final rangeX = math.max(0.001, result.maxX - result.minX);
    final rangeY = math.max(0.001, result.maxY - result.minY);

    final scale = math.min(
      availableWidth / rangeX,
      availableHeight / rangeY,
    );

    final drawWidth = rangeX * scale;
    final drawHeight = rangeY * scale;

    final left = (size.width - drawWidth) / 2;
    final top = (size.height - drawHeight) / 2;

    Offset convert(Offset p) {
      return Offset(
        left + (p.dx - result.minX) * scale,
        size.height - top - (p.dy - result.minY) * scale,
      );
    }

    // رسم شبكة المحاور وحدود مساحة العمل
    final borderPaint = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawRect(
      Rect.fromLTWH(left, top, drawWidth, drawHeight),
      borderPaint,
    );

    // رسم المسار الكامل بلون رمادي
    final remainingPaint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // المسار المنفذ
    final executedPaint = Paint()
      ..color = green
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // حركة G0 السريعة
    final rapidPaint = Paint()
      ..color = Colors.blueAccent
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < result.moves.length; i++) {
      final move = result.moves[i];

      final path = Path();

      if (move.points.isNotEmpty) {
        path.moveTo(
          convert(move.points.first).dx,
          convert(move.points.first).dy,
        );

        for (int j = 1; j < move.points.length; j++) {
          final p = convert(move.points[j]);
          path.lineTo(p.dx, p.dy);
        }
      }

      if (i < executedMoves) {
        canvas.drawPath(path, executedPaint);
      } else if (move.rapid) {
        canvas.drawPath(path, rapidPaint);
      } else {
        canvas.drawPath(path, remainingPaint);
      }
    }

    // موضع بداية المسار
    final startPoint = convert(result.moves.first.start);

    canvas.drawCircle(
      startPoint,
      4,
      Paint()..color = Colors.white,
    );

    // موضع الأداة الحالي
    final currentPoint = convert(toolPosition);

    final toolPaint = Paint()..color = orange;

    canvas.drawCircle(currentPoint, 7, toolPaint);

    canvas.drawCircle(
      currentPoint,
      11,
      Paint()
        ..color = orange.withOpacity(0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant ToolpathPainter oldDelegate) {
    return oldDelegate.data != data ||
        oldDelegate.executedMoves != executedMoves ||
        oldDelegate.toolPosition != toolPosition;
  }
}
