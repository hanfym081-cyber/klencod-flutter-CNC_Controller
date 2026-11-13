
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

void main() => runApp(const Mach3App());

class Mach3App extends StatelessWidget {
  const Mach3App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mach3 Mobile',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF101820),
      ),
      home: const HomePage(),
    );
  }
}

// =====================================================
// TCP CLIENT - MACH3 BRIDGE PROTOCOL 1.0
// =====================================================

class BridgeClient extends ChangeNotifier {
  Socket? socket;
  StreamSubscription<String>? subscription;

  final Map<int, Completer<Map<String, dynamic>>> pending = {};

  int nextId = 1;
  bool connected = false;
  bool connecting = false;

  String host = '192.168.137.1';
  int port = 5000;

  String status = 'غير متصل';
  String? error;

  Map<String, dynamic> machine = {};

  Future<void> connect(String ip, int tcpPort) async {
    await disconnect();

    host = ip.trim();
    port = tcpPort;

    connecting = true;
    status = 'جاري الاتصال';
    error = null;
    notifyListeners();

    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );

      connected = true;
      connecting = false;
      status = 'متصل';

      subscription = socket!
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        receiveMessage,
        onDone: () => connectionLost('انقطع الاتصال'),
        onError: (e) => connectionLost(e.toString()),
      );

      notifyListeners();

      await command('hello', {
        'client': 'Mach3 Mobile',
        'protocol': '1.0',
      });

      await command('get_status');
    } catch (e) {
      connected = false;
      connecting = false;
      status = 'فشل الاتصال';
      error = e.toString();
      notifyListeners();
    }
  }

  void receiveMessage(String line) {
    try {
      final msg = jsonDecode(line) as Map<String, dynamic>;

      if (msg['type'] == 'event') {
        if (msg['name'] == 'status_update' &&
            msg['data'] is Map) {
          machine = Map<String, dynamic>.from(msg['data']);
        }

        notifyListeners();
        return;
      }

      final id = msg['id'];

      if (id is int && pending.containsKey(id)) {
        pending.remove(id)!.complete(msg);
      }

      if (msg['ok'] == false) {
        error = msg['error']?['message']?.toString();
      }

      if (msg['data'] is Map) {
        machine = Map<String, dynamic>.from(msg['data']);
      }

      notifyListeners();
    } catch (e) {
      error = 'رسالة غير مفهومة: $e';
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> command(
    String name, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (!connected || socket == null) {
      return {
        'ok': false,
        'error': {'message': 'لا يوجد اتصال بالكمبيوتر'}
      };
    }

    final id = nextId++;
    final completer = Completer<Map<String, dynamic>>();

    pending[id] = completer;

    final packet = {
      'version': '1.0',
      'id': id,
      'type': 'command',
      'name': name,
      'params': params,
    };

    try {
      socket!.write('${jsonEncode(packet)}\n');

      return await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          pending.remove(id);
          return {
            'ok': false,
            'error': {'message': 'انتهت مهلة الرد'}
          };
        },
      );
    } catch (e) {
      pending.remove(id);
      return {
        'ok': false,
        'error': {'message': e.toString()}
      };
    }
  }

  void connectionLost(String reason) {
    connected = false;
    connecting = false;
    status = 'انقطع الاتصال';
    error = reason;
    socket = null;

    for (final c in pending.values) {
      if (!c.isCompleted) {
        c.complete({
          'ok': false,
          'error': {'message': reason}
        });
      }
    }

    pending.clear();
    notifyListeners();
  }

  Future<void> disconnect() async {
    await subscription?.cancel();
    subscription = null;

    socket?.destroy();
    socket = null;

    connected = false;
    connecting = false;
    status = 'غير متصل';

    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

// =====================================================
// MAIN PAGE
// =====================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final bridge = BridgeClient();

  int selected = 0;

  final titles = [
    'الرئيسية',
    'تشغيل البرنامج',
    'MDI',
    'تحريك المحاور',
    'Toolpath',
    'الإزاحات',
    'جدول الأدوات',
    'التشخيص',
    'الإعدادات',
  ];

  final icons = [
    Icons.dashboard,
    Icons.play_circle,
    Icons.terminal,
    Icons.open_with,
    Icons.route,
    Icons.tune,
    Icons.construction,
    Icons.monitor_heart,
    Icons.settings,
  ];

  @override
  void initState() {
    super.initState();
    bridge.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    bridge.removeListener(refresh);
    bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(bridge: bridge),
      ProgramPage(bridge: bridge),
      MdiPage(bridge: bridge),
      JogPage(bridge: bridge),
      ToolpathPage(bridge: bridge),
      DataPage(bridge: bridge, title: 'الإزاحات', command: 'get_offsets'),
      DataPage(bridge: bridge, title: 'جدول الأدوات', command: 'get_tools'),
      DataPage(bridge: bridge, title: 'التشخيص', command: 'get_diagnostics'),
      SettingsPage(bridge: bridge),
    ];

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(titles[selected]),
          actions: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Chip(
                avatar: Icon(
                  bridge.connected ? Icons.wifi : Icons.wifi_off,
                  color: bridge.connected
                      ? Colors.greenAccent
                      : Colors.orangeAccent,
                ),
                label: Text(bridge.status),
              ),
            ),
          ],
        ),
        drawer: Drawer(
          child: SafeArea(
            child: Column(
              children: [
                const ListTile(
                  title: Text(
                    'MACH3 MOBILE',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text('CNC Wireless Controller'),
                ),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    itemCount: titles.length,
                    itemBuilder: (context, i) => ListTile(
                      leading: Icon(icons[i]),
                      title: Text(titles[i]),
                      selected: selected == i,
                      onTap: () {
                        setState(() => selected = i);
                        Navigator.pop(context);
                      },
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'زر الطوارئ يجب أن يظل مستقلًا وماديًا.',
                    style: TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              ],
            ),
          ),
        ),
        body: SafeArea(child: pages[selected]),
      ),
    );
  }
}

// =====================================================
// COMMON PANEL
// =====================================================

class Panel extends StatelessWidget {
  final String title;
  final Widget child;

  const Panel({
    super.key,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1B2833),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

// =====================================================
// DASHBOARD
// =====================================================

class DashboardPage extends StatelessWidget {
  final BridgeClient bridge;

  const DashboardPage({super.key, required this.bridge});

  @override
  Widget build(BuildContext context) {
    final axes = bridge.machine['axes'] is Map
        ? bridge.machine['axes'] as Map
        : {};

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Panel(
          title: 'الاتصال',
          child: Row(
            children: [
              Icon(
                bridge.connected ? Icons.check_circle : Icons.cancel,
                color: bridge.connected
                    ? Colors.greenAccent
                    : Colors.orangeAccent,
              ),
              const SizedBox(width: 10),
              Text(bridge.status),
            ],
          ),
        ),
        Panel(
          title: 'مواضع المحاور',
          child: Row(
            children: ['x', 'y', 'z'].map((axis) {
              return Expanded(
                child: Column(
                  children: [
                    Text(
                      axis.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 22,
                      ),
                    ),
                    Text(
                      '${axes[axis] ?? '--'}',
                      style: const TextStyle(fontSize: 19),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        Panel(
          title: 'حالة الماكينة',
          child: Wrap(
            spacing: 8,
            children: [
              Chip(
                label: Text(
                  'الحركة: ${bridge.machine['machine_state'] ?? '--'}',
                ),
              ),
              Chip(
                label: Text(
                  'Feed: ${bridge.machine['feed_rate'] ?? '--'}',
                ),
              ),
              Chip(
                label: Text(
                  'Spindle: ${bridge.machine['spindle_speed'] ?? '--'}',
                ),
              ),
            ],
          ),
        ),
        if (bridge.error != null)
          Panel(
            title: 'آخر خطأ',
            child: Text(
              bridge.error!,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          ),
      ],
    );
  }
}

// =====================================================
// PROGRAM RUN
// =====================================================

class ProgramPage extends StatelessWidget {
  final BridgeClient bridge;

  const ProgramPage({super.key, required this.bridge});

  Future<void> send(BuildContext context, String command) async {
    final result = await bridge.command(command);

    if (context.mounted && result['ok'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result['error']?['message'] ?? 'تعذر تنفيذ الأمر',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Panel(
          title: 'التحكم في البرنامج',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => send(context, 'run_program'),
                icon: const Icon(Icons.play_arrow),
                label: const Text('تشغيل'),
              ),
              OutlinedButton.icon(
                onPressed: () => send(context, 'feed_hold'),
                icon: const Icon(Icons.pause),
                label: const Text('إيقاف مؤقت'),
              ),
              OutlinedButton.icon(
                onPressed: () => send(context, 'resume'),
                icon: const Icon(Icons.replay),
                label: const Text('استكمال'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => send(context, 'stop_program'),
                icon: const Icon(Icons.stop),
                label: const Text('إيقاف'),
              ),
            ],
          ),
        ),
        Panel(
          title: 'البرنامج الحالي',
          child: Text(
            '${bridge.machine['program_name'] ?? '--'}',
          ),
        ),
        Panel(
          title: 'سطر التنفيذ',
          child: Text(
            '${bridge.machine['current_line'] ?? '--'}',
          ),
        ),
      ],
    );
  }
}

// =====================================================
// MDI
// =====================================================

class MdiPage extends StatefulWidget {
  final BridgeClient bridge;

  const MdiPage({super.key, required this.bridge});

  @override
  State<MdiPage> createState() => _MdiPageState();
}

class _MdiPageState extends State<MdiPage> {
  final controller = TextEditingController();
  String result = 'جاهز';

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Panel(
          title: 'إدخال G-code',
          child: Column(
            children: [
              TextField(
                controller: controller,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  hintText: 'G0 X0 Y0',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  final code = controller.text.trim();
                  if (code.isEmpty) return;

                  final response = await widget.bridge.command(
                    'execute_mdi',
                    {'code': code},
                  );

                  setState(() {
                    result = response['ok'] == true
                        ? 'تم قبول الرد'
                        : response['error']?['message'] ?? 'فشل الأمر';
                  });
                },
                child: const Text('إرسال الأمر'),
              ),
              const SizedBox(height: 10),
              Text(result),
            ],
          ),
        ),
      ],
    );
  }
}

// =====================================================
// JOG
// =====================================================

class JogPage extends StatefulWidget {
  final BridgeClient bridge;

  const JogPage({super.key, required this.bridge});

  @override
  State<JogPage> createState() => _JogPageState();
}

class _JogPageState extends State<JogPage> {
  double speed = 20;
  double step = 1;
  Timer? heartbeat;
  bool jogging = false;

  Future<void> startJog(String axis, int direction) async {
    if (jogging) return;
    jogging = true;

    await widget.bridge.command('jog_start', {
      'axis': axis,
      'direction': direction,
      'mode': 'continuous',
      'speed_percent': speed,
      'lease_ms': 400,
    });

    heartbeat?.cancel();
    heartbeat = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) {
        widget.bridge.command('jog_start', {
          'axis': axis,
          'direction': direction,
          'mode': 'continuous',
          'speed_percent': speed,
          'lease_ms': 400,
        });
      },
    );
  }

  Future<void> stopJog() async {
    heartbeat?.cancel();
    heartbeat = null;
    jogging = false;
    await widget.bridge.command('jog_stop', {'axis': 'all'});
  }

  @override
  void dispose() {
    heartbeat?.cancel();
    if (jogging) widget.bridge.command('jog_stop', {'axis': 'all'});
    super.dispose();
  }

  Widget holdButton(String label, String axis, int direction) {
    return GestureDetector(
      onLongPressStart: (_) => startJog(axis, direction),
      onLongPressEnd: (_) => stopJog(),
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          color: Colors.blueGrey.shade800,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(fontSize: 26),
          ),
        ),
      ),
    );
  }

  Widget axisRow(String axis) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(
              axis.toUpperCase(),
              style: const TextStyle(fontSize: 20),
            ),
          ),
          Expanded(child: holdButton('−', axis, -1)),
          const SizedBox(width: 10),
          Expanded(child: holdButton('+', axis, 1)),
          IconButton(
            onPressed: () {
              widget.bridge.command('jog_step', {
                'axis': axis,
                'direction': 1,
                'distance': step,
              });
            },
            icon: const Icon(Icons.straighten),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Panel(
          title: 'سرعة التحريك',
          child: Slider(
            value: speed,
            min: 1,
            max: 100,
            divisions: 99,
            label: '${speed.round()}%',
            onChanged: (v) => setState(() => speed = v),
          ),
        ),
        Panel(
          title: 'خطوة التحريك',
          child: DropdownButton<double>(
            value: step,
            isExpanded: true,
            items: [0.001, 0.01, 0.1, 1, 10]
                .map(
                  (v) => DropdownMenuItem(
                    value: v,
                    child: Text('$v'),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => step = v ?? step),
          ),
        ),
        Panel(
          title: 'تحريك المحاور',
          child: Column(
            children: [
              axisRow('x'),
              axisRow('y'),
              axisRow('z'),
              FilledButton.tonal(
                onPressed: stopJog,
                child: const Text('إيقاف التحريك'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =====================================================
// TOOLPATH
// =====================================================

class ToolpathPage extends StatelessWidget {
  final BridgeClient bridge;

  const ToolpathPage({super.key, required this.bridge});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Panel(
          title: 'معاينة مسار الأداة',
          child: AspectRatio(
            aspectRatio: 1,
            child: CustomPaint(
              painter: GridPainter(),
              child: Center(
                child: Text(
                  bridge.machine['toolpath_available'] == true
                      ? 'بيانات المسار متاحة'
                      : 'بانتظار بيانات المسار',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.blueGrey.withOpacity(0.4)
      ..strokeWidth = 1;

    for (double x = 0; x < size.width; x += 24) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        grid,
      );
    }

    for (double y = 0; y < size.height; y += 24) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        grid,
      );
    }

    final center = Paint()
      ..color = Colors.cyanAccent
      ..strokeWidth = 2;

    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      center,
    );

    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      center,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// =====================================================
// DATA PAGES
// =====================================================

class DataPage extends StatefulWidget {
  final BridgeClient bridge;
  final String title;
  final String command;

  const DataPage({
    super.key,
    required this.bridge,
    required this.title,
    required this.command,
  });

  @override
  State<DataPage> createState() => _DataPageState();
}

class _DataPageState extends State<DataPage> {
  Map<String, dynamic>? data;
  String message = 'اضغط تحديث';

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Panel(
          title: widget.title,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: () async {
                  final response = await widget.bridge.command(
                    widget.command,
                  );

                  setState(() {
                    data = response['data'] is Map
                        ? Map<String, dynamic>.from(response['data'])
                        : null;

                    message = response['ok'] == true
                        ? 'تم استلام البيانات'
                        : response['error']?['message'] ?? 'فشل القراءة';
                  });
                },
                icon: const Icon(Icons.refresh),
                label: const Text('تحديث'),
              ),
              const SizedBox(height: 12),
              Text(message),
              if (data != null)
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(data),
                  textDirection: TextDirection.ltr,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// =====================================================
// SETTINGS AND CONNECTION
// =====================================================

class SettingsPage extends StatefulWidget {
  final BridgeClient bridge;

  const SettingsPage({super.key, required this.bridge});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final ip = TextEditingController(text: '192.168.137.1');
  final port = TextEditingController(text: '5000');

  @override
  void dispose() {
    ip.dispose();
    port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Panel(
          title: 'اتصال الكمبيوتر',
          child: Column(
            children: [
              TextField(
                controller: ip,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'IP Address',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: port,
                keyboardType: TextInputType.number,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'TCP Port',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: widget.bridge.connecting
                          ? null
                          : () => widget.bridge.connect(
                                ip.text,
                                int.tryParse(port.text) ?? 5000,
                              ),
                      child: const Text('اتصال'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: widget.bridge.disconnect,
                      child: const Text('فصل الاتصال'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(widget.bridge.status),
              if (widget.bridge.error != null)
                Text(
                  widget.bridge.error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
            ],
          ),
        ),
        const Panel(
          title: 'البروتوكول',
          child: Text(
            'Mach3 Mobile Bridge 1.0\n'
            'TCP/IP\n'
            'JSON Lines\n'
            'UTF-8\n'
            'Port 5000',
          ),
        ),
        const Panel(
          title: 'تنبيه أمان',
          child: Text(
            'التطبيق ليس بديلًا عن زر الطوارئ المادي. '
            'لا تختبر أوامر الحركة قبل تجهيز Windows Bridge '
            'والتحقق من حدود الحركة ووسائل الأمان.',
          ),
        ),
      ],
    );
  }
}
