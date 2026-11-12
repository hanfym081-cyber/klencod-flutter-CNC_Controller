
import 'dart:async';
import 'package:flutter/material.dart';

void main() {
  runApp(const CNCApp());
}

const bg = Color(0xFF0D1117);
const panel = Color(0xFF161B22);
const border = Color(0xFF30363D);
const blue = Color(0xFF388BFD);
const green = Color(0xFF3FB950);
const red = Color(0xFFF85149);
const muted = Color(0xFF8B949E);

class CNCApp extends StatelessWidget {
  const CNCApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CNC Controller',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          primary: blue,
          surface: panel,
        ),
        useMaterial3: true,
      ),
      home: const CNCPage(),
    );
  }
}

class CNCPage extends StatefulWidget {
  const CNCPage({super.key});

  @override
  State<CNCPage> createState() => _CNCPageState();
}

class _CNCPageState extends State<CNCPage> {
  double x = 0;
  double y = 0;
  double z = 0;

  double feed = 50;
  double rpm = 1200;

  // مسافة الحركة لكل ضغطة
  double jogStep = 1.0;

  bool spindle = false;
  bool running = false;
  bool alarm = false;

  Timer? timer;

  String get machineStatus {
    if (alarm) return 'إنذار طوارئ';
    if (running) return 'الماكينة تعمل';
    return 'الماكينة متوقفة';
  }

  Color get statusColor {
    if (alarm) return red;
    if (running) return green;
    return muted;
  }

  void jog(String axis, double amount) {
    if (alarm || running) return;

    setState(() {
      if (axis == 'X') x = (x + amount).clamp(-500.0, 500.0);
      if (axis == 'Y') y = (y + amount).clamp(-500.0, 500.0);
      if (axis == 'Z') z = (z + amount).clamp(-200.0, 200.0);
    });
  }

  void startSimulation() {
    if (alarm) return;

    timer?.cancel();

    setState(() {
      running = true;
    });

    timer = Timer.periodic(
      const Duration(milliseconds: 200),
      (t) {
        if (!mounted || alarm) {
          t.cancel();
          return;
        }

        setState(() {
          x += 0.1 * feed / 50;
          y += 0.05 * feed / 50;

          if (x > 500) x = -500;
          if (y > 500) y = -500;
        });
      },
    );
  }

  void stopSimulation() {
    timer?.cancel();

    setState(() {
      running = false;
    });
  }

  void emergencyStop() {
    timer?.cancel();

    setState(() {
      running = false;
      spindle = false;
      alarm = true;
    });
  }

  void resetAlarm() {
    setState(() {
      alarm = false;
      running = false;
      spindle = false;
    });
  }

  void resetCoordinates() {
    if (alarm || running) return;

    setState(() {
      x = 0;
      y = 0;
      z = 0;
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Widget card({
    required String title,
    required Widget child,
    IconData? icon,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: blue, size: 21),
                const SizedBox(width: 9),
              ],
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget axisCard(String name, double value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          Text(
            'محور $name',
            style: const TextStyle(
              color: blue,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          FittedBox(
            child: Text(
              value.toStringAsFixed(3),
              style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const Text(
            'mm',
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: jogButton(
                  label: '-',
                  color: red,
                  onTap: () => jog(name, -jogStep),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: jogButton(
                  label: '+',
                  color: green,
                  onTap: () => jog(name, jogStep),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget jogButton({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 43,
      child: FilledButton(
        onPressed: alarm || running ? null : onTap,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          disabledBackgroundColor: muted.withOpacity(0.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget actionButton(
    String title,
    IconData icon,
    Color color,
    VoidCallback? action,
  ) {
    return Expanded(
      child: FilledButton.icon(
        onPressed: action,
        icon: Icon(icon),
        label: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: color,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  Widget buildJogSelector() {
    return DropdownButtonFormField<double>(
      value: jogStep,
      decoration: const InputDecoration(
        labelText: 'مسافة الحركة لكل ضغطة',
        suffixText: 'mm',
        border: OutlineInputBorder(),
      ),
      items: const [
        DropdownMenuItem(value: 0.01, child: Text('0.01 mm')),
        DropdownMenuItem(value: 0.1, child: Text('0.1 mm')),
        DropdownMenuItem(value: 1.0, child: Text('1 mm')),
        DropdownMenuItem(value: 10.0, child: Text('10 mm')),
      ],
      onChanged: alarm || running
          ? null
          : (value) {
              if (value != null) {
                setState(() => jogStep = value);
              }
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: panel,
          title: const Text(
            'CNC CONTROLLER',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          leading: const Icon(Icons.precision_manufacturing),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              card(
                title: 'حالة الماكينة',
                icon: Icons.monitor_heart,
                child: Row(
                  children: [
                    Icon(Icons.circle, color: statusColor, size: 15),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        machineStatus,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Text(
                      alarm ? 'ALARM' : running ? 'RUN' : 'IDLE',
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),

              card(
                title: 'إحداثيات المحاور',
                icon: Icons.control_camera,
                child: Column(
                  children: [
                    buildJogSelector(),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: axisCard('X', x)),
                        const SizedBox(width: 8),
                        Expanded(child: axisCard('Y', y)),
                        const SizedBox(width: 8),
                        Expanded(child: axisCard('Z', z)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: alarm || running
                            ? null
                            : resetCoordinates,
                        icon: const Icon(Icons.home),
                        label: const Text('تصفير الإحداثيات'),
                      ),
                    ),
                  ],
                ),
              ),

              card(
                title: 'الاسبيندل',
                icon: Icons.settings,
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('سرعة الدوران'),
                        Text(
                          '${spindle ? rpm.toInt() : 0} RPM',
                          style: const TextStyle(
                            color: blue,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: rpm,
                      min: 0,
                      max: 6000,
                      divisions: 60,
                      onChanged: alarm
                          ? null
                          : (v) => setState(() => rpm = v),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: alarm
                            ? null
                            : () => setState(() {
                                  spindle = !spindle;
                                }),
                        icon: Icon(
                          spindle
                              ? Icons.stop_circle
                              : Icons.play_circle,
                        ),
                        label: Text(
                          spindle
                              ? 'إيقاف الاسبيندل'
                              : 'تشغيل الاسبيندل',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: spindle ? red : green,
                          padding: const EdgeInsets.all(14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              card(
                title: 'سرعة التغذية Feed Rate',
                icon: Icons.speed,
                child: Column(
                  children: [
                    Text(
                      '${feed.toInt()}%',
                      style: const TextStyle(
                        fontSize: 25,
                        color: blue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Slider(
                      value: feed,
                      min: 0,
                      max: 100,
                      divisions: 100,
                      onChanged: alarm
                          ? null
                          : (v) => setState(() => feed = v),
                    ),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('0%', style: TextStyle(color: muted)),
                        Text('100%', style: TextStyle(color: muted)),
                      ],
                    ),
                  ],
                ),
              ),

              card(
                title: 'التحكم في المحاكاة',
                icon: Icons.play_circle_outline,
                child: Row(
                  children: [
                    actionButton(
                      'تشغيل',
                      Icons.play_arrow,
                      green,
                      alarm || running ? null : startSimulation,
                    ),
                    const SizedBox(width: 10),
                    actionButton(
                      'إيقاف',
                      Icons.stop,
                      blue,
                      running ? stopSimulation : null,
                    ),
                  ],
                ),
              ),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: red.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: red),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.warning_rounded,
                      color: red,
                      size: 32,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'إيقاف الطوارئ',
                      style: TextStyle(
                        color: red,
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: alarm ? null : emergencyStop,
                        style: FilledButton.styleFrom(
                          backgroundColor: red,
                          padding: const EdgeInsets.all(16),
                        ),
                        child: const Text(
                          'إيقاف فوري للطوارئ',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    if (alarm) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: resetAlarm,
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('إعادة ضبط الإنذار'),
                      ),
                    ],
                  ],
                ),
              ),

              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'CNC Simulator V1.1 - محاكاة تعليمية فقط',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
