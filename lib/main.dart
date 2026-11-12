
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const Mach3Remote());
}

const bg = Color(0xFF171C22);
const panel = Color(0xFF252D36);
const green = Color(0xFF36D17C);
const orange = Color(0xFFFFA62B);

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
        colorScheme: ColorScheme.dark(
          primary: green,
          surface: panel,
        ),
        useMaterial3: true,
      ),
      home: const ControllerScreen(),
    );
  }
}

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  String ip = '192.168.1.100';
  String port = '8765';

  String selectedAxis = 'X';
  String jogStep = '1.0';

  bool connected = false;
  bool machineRunning = false;

  double x = 0;
  double y = 0;
  double z = 0;
  double feed = 100;
  double rpm = 0;

  @override
  void initState() {
    super.initState();
    loadSettings();
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      ip = prefs.getString('ip') ?? ip;
      port = prefs.getString('port') ?? port;
    });
  }

  Future<void> saveSettings(String newIp, String newPort) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ip', newIp);
    await prefs.setString('port', newPort);

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

  void jog(String axis, double direction) {
    if (!connected) {
      notify('الاتصال غير متاح - أمر تجريبي فقط');
      return;
    }

    final amount = double.tryParse(jogStep) ?? 1;

    setState(() {
      if (axis == 'X') x += amount * direction;
      if (axis == 'Y') y += amount * direction;
      if (axis == 'Z') z += amount * direction;
    });

    // لا يوجد إرسال حقيقي إلى Mach3 في هذه النسخة.
  }

  Widget panelBox({
    required String title,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(10),
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
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget axisDisplay(String axis, double value) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF11161C),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          children: [
            Text(
              axis,
              style: const TextStyle(
                color: orange,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 5),
            FittedBox(
              child: Text(
                value.toStringAsFixed(3),
                style: const TextStyle(
                  fontSize: 20,
                  fontFamily: 'monospace',
                  color: green,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget actionButton(
    String text,
    VoidCallback action, {
    Color color = panel,
    double height = 48,
  }) {
    return SizedBox(
      height: height,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.all(5),
        ),
        onPressed: action,
        child: FittedBox(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget jogButton(String label, String axis, double direction) {
    return SizedBox(
      width: 75,
      height: 52,
      child: ElevatedButton(
        onPressed: () => jog(axis, direction),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF344452),
          foregroundColor: Colors.white,
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Future<void> showSettings() async {
    final ipController = TextEditingController(text: ip);
    final portController = TextEditingController(text: port);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: panel,
        title: const Text('إعدادات الاتصال'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ipController,
              keyboardType: TextInputType.number,
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
            onPressed: () => Navigator.pop(context),
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
              if (context.mounted) Navigator.pop(context);
              notify('تم حفظ الإعدادات');
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF202832),
        title: const Text(
          'MACH3 REMOTE',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        actions: [
          IconButton(
            onPressed: showSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              panelBox(
                title: 'CONNECTION',
                child: Row(
                  children: [
                    Icon(
                      connected ? Icons.wifi : Icons.wifi_off,
                      color: connected ? green : Colors.redAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        connected ? 'متصل' : 'غير متصل',
                        style: TextStyle(
                          color: connected ? green : Colors.redAccent,
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        notify(
                          'الاتصال الحقيقي سيتم تفعيله في المرحلة القادمة',
                        );
                      },
                      child: const Text('اتصال'),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              panelBox(
                title: 'TOOLPATH DISPLAY',
                child: Container(
                  height: 190,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF101820),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: CustomPaint(
                    painter: ToolpathPainter(),
                    child: const Center(
                      child: Text(
                        'TOOLPATH VIEW',
                        style: TextStyle(
                          color: Colors.white24,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              panelBox(
                title: 'MACHINE COORDINATES - DRO',
                child: Row(
                  children: [
                    axisDisplay('X', x),
                    axisDisplay('Y', y),
                    axisDisplay('Z', z),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              panelBox(
                title: 'JOG CONTROL',
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('AXIS  '),
                        ...['X', 'Y', 'Z'].map(
                          (axis) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: ChoiceChip(
                              label: Text(axis),
                              selected: selectedAxis == axis,
                              onSelected: (_) {
                                setState(() => selectedAxis = axis);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('STEP  '),
                        DropdownButton<String>(
                          value: jogStep,
                          items: ['0.01', '0.1', '1.0', '10.0']
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v,
                                  child: Text('$v mm'),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) {
                              setState(() => jogStep = v);
                            }
                          },
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        jogButton('−', selectedAxis, -1),
                        const SizedBox(width: 12),
                        jogButton('+', selectedAxis, 1),
                      ],
                    ),

                    const SizedBox(height: 10),

                    const Text(
                      'اختيار المحور ثم الضغط على + أو -',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              panelBox(
                title: 'MACHINE CONTROL',
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: actionButton(
                            'CYCLE START',
                            () => notify('سيتم ربط الأمر بـ Mach3 لاحقاً'),
                            color: const Color(0xFF167A42),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: actionButton(
                            'FEED HOLD',
                            () => notify('سيتم ربط الأمر بـ Mach3 لاحقاً'),
                            color: const Color(0xFFAA7621),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    actionButton(
                      'STOP',
                      () => notify('زر تجريبي - ليس إيقاف طوارئ حقيقي'),
                      color: Colors.red.shade900,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              panelBox(
                title: 'SPINDLE / FEED',
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('RPM: ${rpm.toInt()}'),
                        Text('FEED: ${feed.toInt()}%'),
                      ],
                    ),
                    Slider(
                      value: feed,
                      min: 10,
                      max: 150,
                      onChanged: (v) => setState(() => feed = v),
                    ),
                    const Text(
                      'القيم تجريبية حتى ربط Mach3',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 15),
              const Text(
                'MACH3 REMOTE - LOCAL NETWORK',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ToolpathPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.6;

    for (double i = 0; i < size.width; i += 20) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), gridPaint);
    }

    for (double i = 0; i < size.height; i += 20) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), gridPaint);
    }

    final pathPaint = Paint()
      ..color = green
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path();
    path.moveTo(size.width * 0.2, size.height * 0.3);
    path.lineTo(size.width * 0.8, size.height * 0.3);
    path.lineTo(size.width * 0.8, size.height * 0.7);
    path.lineTo(size.width * 0.2, size.height * 0.7);
    path.close();

    canvas.drawPath(path, pathPaint);

    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
      center,
      4,
      Paint()..color = orange,
    );

    final axisPaint = Paint()
      ..strokeWidth = 2
      ..color = Colors.redAccent;

    canvas.drawLine(
      center,
      Offset(center.dx + 35, center.dy),
      axisPaint,
    );

    canvas.drawLine(
      center,
      Offset(center.dx, center.dy - 35),
      Paint()
        ..color = Colors.blueAccent
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
