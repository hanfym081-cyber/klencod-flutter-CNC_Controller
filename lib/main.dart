
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

void main() {
  runApp(const Mach3Remote());
}

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
        colorScheme: const ColorScheme.dark(
          primary: green,
          surface: panel,
        ),
        useMaterial3: true,
      ),
      home: const MainScreen(),
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
  bool machineRunning = false;

  String selectedAxis = 'X';
  String jogStep = '1.0';

  String fileName = 'لم يتم اختيار ملف';
  String fileInfo = '';

  double x = 0;
  double y = 0;
  double z = 0;
  double feed = 100;
  double rpm = 0;
  double spindleOverride = 100;

  @override
  void initState() {
    super.initState();
    loadSettings();
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
  }

  void notify(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textAlign: TextAlign.center),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void unavailable(String command) {
    notify('$command: سيتم تفعيله بعد تجهيز برنامج Windows');
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
                hintText: '192.168.1.100',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '8765',
              ),
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
              notify('تم حفظ الإعدادات');
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );

    ipController.dispose();
    portController.dispose();
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

      setState(() {
        fileName = selected.name;
        fileInfo = 'الحجم: ${(selected.size / 1024).toStringAsFixed(1)} KB';
      });

      notify('تم اختيار الملف. إرساله للكمبيوتر سيتم تفعيله لاحقاً');
    } catch (e) {
      notify('تعذر فتح الملف');
    }
  }

  void jog(String axis, double direction) {
    if (!connected) {
      notify('اتصل بالكمبيوتر أولاً');
      return;
    }

    unavailable('تحريك المحور $axis');
  }

  void emergencyStop() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: panel,
        title: const Text(
          'إيقاف طارئ عن بُعد',
          style: TextStyle(color: red),
        ),
        content: const Text(
          'هذا الزر لم يتم ربطه بعد ببرنامج Mach3. '
          'ولا يغني عن دائرة الطوارئ المادية المستقلة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
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
    IconData? icon,
  }) {
    return SizedBox(
      height: 48,
      child: ElevatedButton.icon(
        onPressed: action,
        icon: Icon(icon ?? Icons.circle, size: 16),
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
                value.toStringAsFixed(3),
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

  Widget buildProgramScreen() {
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
              Text(
                fileInfo,
                style: const TextStyle(color: Colors.white54),
              ),
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
          child: Container(
            height: 190,
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFF101820),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const CustomPaint(
              painter: ToolpathPainter(),
              child: Center(
                child: Text(
                  'معاينة تجريبية - ليست مسار الملف',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
            ),
          ),
        ),
        panelBox(
          title: 'PROGRAM RUN',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: actionButton(
                      'CYCLE START',
                      () => unavailable('Cycle Start'),
                      color: const Color(0xFF167A42),
                      icon: Icons.play_arrow,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: actionButton(
                      'FEED HOLD',
                      () => unavailable('Feed Hold'),
                      color: const Color(0xFFAA7621),
                      icon: Icons.pause,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              actionButton(
                'STOP',
                () => unavailable('Stop'),
                color: Colors.red.shade900,
                icon: Icons.stop,
              ),
              const SizedBox(height: 12),
              const LinearProgressIndicator(value: 0),
              const SizedBox(height: 8),
              const Text(
                'السطر الحالي: --     التقدم: 0%',
                style: TextStyle(color: Colors.white54),
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
        panelBox(
          title: 'SELECT AXIS',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: ['X', 'Y', 'Z'].map((axis) {
              return ChoiceChip(
                label: Text(
                  axis,
                  style: const TextStyle(fontSize: 18),
                ),
                selected: selectedAxis == axis,
                onSelected: (_) {
                  setState(() => selectedAxis = axis);
                },
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
            items: ['0.01', '0.1', '1.0', '10.0']
                .map(
                  (v) => DropdownMenuItem(
                    value: v,
                    child: Text('$v mm'),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => jogStep = v);
            },
          ),
        ),
        panelBox(
          title: 'JOG CONTROL',
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 105,
                    height: 65,
                    child: actionButton(
                      '−',
                      () => jog(selectedAxis, -1),
                      icon: Icons.remove,
                    ),
                  ),
                  const SizedBox(width: 20),
                  SizedBox(
                    width: 105,
                    height: 65,
                    child: actionButton(
                      '+',
                      () => jog(selectedAxis, 1),
                      icon: Icons.add,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              actionButton(
                'HOME ALL',
                () => unavailable('Home All'),
                icon: Icons.home,
              ),
              const SizedBox(height: 12),
              const Text(
                'أوامر الحركة لن تعمل قبل ربط برنامج Windows',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
        panelBox(
          title: 'JOG SPEED',
          child: Column(
            children: [
              const Text('سرعة الحركة'),
              Slider(
                value: feed,
                min: 1,
                max: 100,
                onChanged: (v) => setState(() => feed = v),
              ),
              Text('${feed.toInt()}%'),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildCoordinatesScreen() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        panelBox(
          title: 'MACHINE COORDINATES',
          child: Row(
            children: [
              valueBox('X', x),
              valueBox('Y', y),
              valueBox('Z', z),
            ],
          ),
        ),
        panelBox(
          title: 'WORK COORDINATES',
          child: Row(
            children: [
              valueBox('X', 0),
              valueBox('Y', 0),
              valueBox('Z', 0),
            ],
          ),
        ),
        panelBox(
          title: 'ZERO AXIS',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: actionButton(
                      'ZERO X',
                      () => unavailable('Zero X'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: actionButton(
                      'ZERO Y',
                      () => unavailable('Zero Y'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: actionButton(
                      'ZERO Z',
                      () => unavailable('Zero Z'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              actionButton(
                'ZERO ALL',
                () => unavailable('Zero All'),
                color: const Color(0xFF167A42),
              ),
            ],
          ),
        ),
        panelBox(
          title: 'WORK OFFSET',
          child: Column(
            children: [
              const Text('Coordinate System'),
              DropdownButtonFormField<String>(
                value: 'G54',
                items: ['G54', 'G55', 'G56', 'G57', 'G58', 'G59']
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(v),
                      ),
                    )
                    .toList(),
                onChanged: (_) => unavailable('تغيير نظام الإحداثيات'),
              ),
              const SizedBox(height: 12),
              actionButton(
                'TOOL ZERO',
                () => unavailable('Tool Zero'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildSpeedScreen() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        panelBox(
          title: 'SPINDLE',
          child: Column(
            children: [
              Text(
                'RPM: ${rpm.toInt()}',
                style: const TextStyle(fontSize: 24, color: green),
              ),
              Slider(
                value: rpm,
                min: 0,
                max: 10000,
                onChanged: (v) => setState(() => rpm = v),
              ),
              Row(
                children: [
                  Expanded(
                    child: actionButton(
                      'SPINDLE ON',
                      () => unavailable('Spindle On'),
                      color: const Color(0xFF167A42),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: actionButton(
                      'SPINDLE OFF',
                      () => unavailable('Spindle Off'),
                      color: Colors.red.shade900,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        panelBox(
          title: 'FEED RATE OVERRIDE',
          child: Column(
            children: [
              Text(
                '${feed.toInt()}%',
                style: const TextStyle(fontSize: 24, color: green),
              ),
              Slider(
                value: feed,
                min: 10,
                max: 150,
                onChanged: (v) => setState(() => feed = v),
              ),
              const Text('Feed Override'),
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
        panelBox(
          title: 'COOLANT',
          child: Row(
            children: [
              Expanded(
                child: actionButton(
                  'COOLANT ON',
                  () => unavailable('Coolant On'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: actionButton(
                  'COOLANT OFF',
                  () => unavailable('Coolant Off'),
                  color: Colors.red.shade900,
                ),
              ),
            ],
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
              const SizedBox(height: 5),
              Text(
                fileInfo,
                style: const TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 15),
              actionButton(
                'اختيار ملف من الموبايل',
                chooseFile,
                icon: Icons.folder_open,
              ),
              const SizedBox(height: 10),
              actionButton(
                'إرسال الملف إلى الكمبيوتر',
                () => unavailable('إرسال الملف'),
                icon: Icons.upload,
              ),
              const SizedBox(height: 10),
              actionButton(
                'تحميل الملف داخل Mach3',
                () => unavailable('تحميل الملف'),
                icon: Icons.file_download,
              ),
            ],
          ),
        ),
        panelBox(
          title: 'FILE CONTENT',
          child: const SizedBox(
            height: 120,
            child: Center(
              child: Text(
                'سيظهر محتوى G-code بعد تجهيز قارئ الملفات',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
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
              const SizedBox(height: 5),
              Text(
                ip,
                style: const TextStyle(color: green, fontSize: 19),
              ),
              const SizedBox(height: 12),
              const Text('Port'),
              const SizedBox(height: 5),
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
                connected ? 'متصل' : 'غير متصل',
                style: TextStyle(
                  color: connected ? green : red,
                  fontSize: 20,
                ),
              ),
              const SizedBox(height: 15),
              actionButton(
                'اتصال بالكمبيوتر',
                () => unavailable('الاتصال'),
                icon: Icons.wifi,
              ),
              const SizedBox(height: 10),
              actionButton(
                'فصل الاتصال',
                () => setState(() => connected = false),
                color: Colors.red.shade900,
                icon: Icons.wifi_off,
              ),
            ],
          ),
        ),
        panelBox(
          title: 'SYSTEM',
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Controller: Mach3 Mill'),
              SizedBox(height: 8),
              Text('Network: Wi-Fi Local Network'),
              SizedBox(height: 8),
              Text('Protocol: WebSocket - سيتم تفعيله لاحقاً'),
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
        return buildCoordinatesScreen();
      case 3:
        return buildSpeedScreen();
      case 4:
        return buildFilesScreen();
      default:
        return buildConnectionScreen();
    }
  }

  final List<String> pageTitles = [
    'PROGRAM RUN',
    'JOG CONTROL',
    'COORDINATES',
    'SPINDLE / FEED',
    'FILES',
    'CONNECTION',
  ];

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
          Container(
            margin: const EdgeInsets.symmetric(vertical: 7),
            child: ElevatedButton.icon(
              onPressed: emergencyStop,
              icon: const Icon(Icons.warning, size: 17),
              label: const Text(
                'E-STOP',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
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
        onDestinationSelected: (index) {
          setState(() => page = index);
        },
        backgroundColor: const Color(0xFF202832),
        indicatorColor: green.withValues(alpha: 0.18),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline),
            label: 'البرنامج',
          ),
          NavigationDestination(
            icon: Icon(Icons.gamepad),
            label: 'الحركة',
          ),
          NavigationDestination(
            icon: Icon(Icons.my_location),
            label: 'الإحداثيات',
          ),
          NavigationDestination(
            icon: Icon(Icons.speed),
            label: 'السرعات',
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

class ToolpathPainter extends CustomPainter {
  const ToolpathPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.white12
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

    final pathPaint = Paint()
      ..color = green
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(size.width * 0.2, size.height * 0.3)
      ..lineTo(size.width * 0.8, size.height * 0.3)
      ..lineTo(size.width * 0.8, size.height * 0.7)
      ..lineTo(size.width * 0.2, size.height * 0.7)
      ..close();

    canvas.drawPath(path, pathPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
