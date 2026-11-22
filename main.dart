import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const SmartElevatorApp());

const kBg = Color(0xFF0F1226);
const kCard = Color(0xFF1B1F3B);
const kAccent = Color(0xFF6C63FF);
const kGreen = Color(0xFF2ED8A3);
const kRed = Color(0xFFFF5C7A);

// ---------------------------------------------------------------------------
// Time (in seconds) the real elevator needs for each floor-to-floor leg.
// Key = the floor the leg starts from. Change these numbers if you re-measure.
//   up:   1 -> 2 = 9s,  2 -> 3 = 10s   (so 1 -> 3 = 19s)
//   down: 3 -> 2 = 7s,  2 -> 1 = 7s    (so 3 -> 1 = 14s)
// ---------------------------------------------------------------------------
const Map<int, double> kUpSecs = {1: 9.0, 2: 10.0};
const Map<int, double> kDownSecs = {3: 7.0, 2: 7.0};

/// Cabin position (1.0 = floor 1 ... 3.0 = floor 3) after [elapsed] seconds
/// of a trip from floor [from] to floor [to].
double tripPosition(int from, int to, double elapsed) {
  if (from == to) return from.toDouble();
  final up = to > from;
  final step = up ? 1 : -1;
  double pos = from.toDouble();
  double left = elapsed;
  int f = from;
  while (f != to) {
    final d = (up ? kUpSecs[f] : kDownSecs[f]) ?? 8.0;
    if (left >= d) {
      left -= d;
      f += step;
      pos = f.toDouble();
    } else {
      pos += step * left / d;
      break;
    }
  }
  return pos;
}

class SmartElevatorApp extends StatelessWidget {
  const SmartElevatorApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Smart Elevator',
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: kBg),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  BluetoothConnection? _conn;
  bool get connected => _conn?.isConnected ?? false;
  bool _connecting = false;
  String _typed = '';

  // ---- elevator status (comes from the Arduino as "UP,1,3" / "STOP,2,2") ----
  String _state = 'STOP'; // UP / DOWN / STOP
  int _fromFloor = 1;
  int _toFloor = 1;
  DateTime? _tripStart; // when the current trip was first reported
  bool _hasStatus = false; // true once the elevator has reported at least once
  String _rx = ''; // incoming bytes waiting for a newline
  final ValueNotifier<double> _pos = ValueNotifier<double>(1.0);
  double _target = 1.0; // where the cabin glides to when stopped
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  void _kick() {
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    var dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    if (dt < 0) dt = 0;
    _lastTick = elapsed;

    if (_state != 'STOP' && _tripStart != null) {
      final secs = DateTime.now().difference(_tripStart!).inMilliseconds / 1000.0;
      _pos.value = tripPosition(_fromFloor, _toFloor, secs);
    } else {
      final diff = _target - _pos.value;
      if (diff.abs() < 0.002) {
        _pos.value = _target;
        _ticker.stop();
      } else {
        _pos.value += diff * (1 - math.exp(-dt * 9));
      }
    }
  }

  void _resetStatus() {
    _hasStatus = false;
    _state = 'STOP';
    _tripStart = null;
    _rx = '';
  }

  void _onData(Uint8List data) {
    _rx += utf8.decode(data, allowMalformed: true);
    if (_rx.length > 300) _rx = '';
    var nl = _rx.indexOf('\n');
    while (nl != -1) {
      final line = _rx.substring(0, nl).trim();
      _rx = _rx.substring(nl + 1);
      if (line.isNotEmpty) _onStatus(line);
      nl = _rx.indexOf('\n');
    }
  }

  void _onStatus(String line) {
    final p = line.split(',');
    if (p.length != 3) return;
    final st = p[0].trim().toUpperCase();
    final from = int.tryParse(p[1].trim());
    final to = int.tryParse(p[2].trim());
    if (from == null || to == null) return;
    if (st != 'UP' && st != 'DOWN' && st != 'STOP') return;
    if (!mounted) return;

    if (st == 'STOP') {
      final f = to.clamp(1, 3).toDouble();
      _state = 'STOP';
      _tripStart = null;
      _fromFloor = to;
      _toFloor = to;
      _target = f;
      if (!_hasStatus) _pos.value = f;
      if ((_pos.value - f).abs() > 0.002) _kick();
    } else {
      final newTrip =
          _state != st || _fromFloor != from || _toFloor != to || _tripStart == null;
      _state = st;
      if (newTrip) {
        _fromFloor = from;
        _toFloor = to;
        _tripStart = DateTime.now();
      }
      _kick();
    }
    _hasStatus = true;
    setState(() {});
  }

  // raw = exactly what the elevator receives, label = what the user sees
  Future<void> _send(String raw, [String? label]) async {
    if (!connected) {
      _toast('Not connected');
      return;
    }
    try {
      _conn!.output.add(Uint8List.fromList(utf8.encode(raw)));
      await _conn!.output.allSent;
      _toast('Sent: ${label ?? raw}');
    } catch (_) {
      _toast('Send failed');
    }
  }

  void _toast(String m) {
    final s = ScaffoldMessenger.of(context);
    s.hideCurrentSnackBar();
    s.showSnackBar(
        SnackBar(content: Text(m), duration: const Duration(milliseconds: 800)));
  }

  Future<void> _onConnectTap() async {
    if (connected) {
      await _conn?.close();
      if (mounted) {
        setState(() {
          _conn = null;
          _resetStatus();
        });
      }
      return;
    }
    await [Permission.bluetoothConnect, Permission.bluetoothScan, Permission.location]
        .request();
    final state = await FlutterBluetoothSerial.instance.state;
    if (state != BluetoothState.STATE_ON) {
      await FlutterBluetoothSerial.instance.requestEnable();
    }
    final devices = await FlutterBluetoothSerial.instance.getBondedDevices();
    if (!mounted) return;
    final picked = await showModalBottomSheet<BluetoothDevice>(
      context: context,
      backgroundColor: kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(18),
              child: Text('Bluetooth devices',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            if (devices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(18),
                child: Text('No paired devices. Pair the elevator from phone settings first.'),
              ),
            for (final d in devices)
              ListTile(
                leading: const Icon(Icons.bluetooth, color: kAccent),
                title: Text(d.name ?? 'Unknown'),
                subtitle: Text(d.address),
                onTap: () => Navigator.pop(context, d),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _connecting = true);
    try {
      final c = await BluetoothConnection.toAddress(picked.address);
      c.input?.listen(_onData).onDone(() {
        if (mounted) {
          setState(() {
            _conn = null;
            _resetStatus();
          });
        }
      });
      if (mounted) {
        setState(() {
          _conn = c;
          _resetStatus();
        });
      }
    } catch (_) {
      _toast('Connection failed');
      if (mounted) {
        setState(() {
          _conn = null;
          _resetStatus();
        });
      }
    }
    if (mounted) setState(() => _connecting = false);
  }

  void _key(String k) {
    if (k == 'OK') {
      _send('#', 'OK');
      setState(() => _typed = '');
    } else if (k == 'Delete') {
      _send('*', 'Delete');
      setState(() => _typed = '');
    } else {
      _send(k);
      if (_typed.length < 8) setState(() => _typed += k);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pos.dispose();
    _conn?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = connected ? kGreen : kRed;
    final label = _connecting ? 'Connecting...' : (connected ? 'Connected' : 'Disconnected');
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            children: [
              // Connection button
              GestureDetector(
                onTap: _connecting ? null : _onConnectTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: color, width: 1.5),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                          color: color),
                      const SizedBox(width: 10),
                      Text(label,
                          style: TextStyle(
                              color: color, fontSize: 18, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              // Title
              const Text('Smart Elevator',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 1)),
              const SizedBox(height: 14),
              // Live elevator drawing
              ValueListenableBuilder<double>(
                valueListenable: _pos,
                builder: (_, pos, __) => ElevatorView(
                  pos: pos,
                  state: _state,
                  online: connected && _hasStatus,
                ),
              ),
              const SizedBox(height: 22),
              // Floors
              Row(
                children: [
                  for (int i = 1; i <= 3; i++) ...[
                    Expanded(child: _floorButton(i)),
                    if (i < 3) const SizedBox(width: 12),
                  ]
                ],
              ),
              const SizedBox(height: 28),
              // Password display
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration:
                    BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16)),
                child: Text(
                  _typed.isEmpty ? 'Password' : '•' * _typed.length,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 24,
                      letterSpacing: 6,
                      color: _typed.isEmpty ? Colors.white38 : Colors.white),
                ),
              ),
              const SizedBox(height: 16),
              // Keypad
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.5,
                children: [
                  for (final k in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
                    _keyButton(k, kCard),
                  _keyButton('Delete', kRed.withOpacity(0.85), small: true),
                  _keyButton('0', kCard),
                  _keyButton('OK', kGreen.withOpacity(0.9), dark: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _floorButton(int n) => Material(
        color: kAccent,
        borderRadius: BorderRadius.circular(20),
        elevation: 6,
        shadowColor: kAccent.withOpacity(0.5),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          splashColor: Colors.white30,
          highlightColor: Colors.white12,
          onTap: () {
            HapticFeedback.mediumImpact();
            _send('floor $n\n', 'floor $n');
          },
          child: SizedBox(
            height: 110,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Floor',
                    style: TextStyle(fontSize: 14, color: Colors.white70)),
                Text('$n',
                    style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
      );

  Widget _keyButton(String k, Color bg, {bool small = false, bool dark = false}) =>
      Material(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _key(k),
          child: Center(
            child: Text(k,
                style: TextStyle(
                    fontSize: small ? 16 : 24,
                    fontWeight: FontWeight.w700,
                    color: dark ? kBg : Colors.white)),
          ),
        ),
      );
}

/// The elevator drawing: a shaft with a moving cabin, floor numbers on the
/// left and a digital floor / direction display on the right.
class ElevatorView extends StatelessWidget {
  const ElevatorView({
    super.key,
    required this.pos,
    required this.state,
    required this.online,
  });

  final double pos; // 1.0 (floor 1) ... 3.0 (floor 3), fractions = between floors
  final String state; // UP / DOWN / STOP
  final bool online; // false when disconnected or no status received yet

  static const double _shaftW = 120;
  static const double _shaftH = 210;
  static const double _cabH = 58;
  static const double _pad = 10;
  static const double _travel = _shaftH - _cabH - 2 * _pad;

  double _levelBottom(int floor) => _pad + (floor - 1) / 2 * _travel;

  @override
  Widget build(BuildContext context) {
    final frac = ((pos - 1) / 2).clamp(0.0, 1.0).toDouble();
    final cabBottom = _pad + frac * _travel;
    final floor = pos.round().clamp(1, 3).toInt();
    final moving = online && state != 'STOP';

    final cabin = Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF9A8CFF), kAccent],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white30),
        boxShadow: [
          BoxShadow(
            color: kAccent.withOpacity(moving ? 0.7 : 0.3),
            blurRadius: moving ? 20 : 10,
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(5, 5, 1.5, 5),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.18),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(1.5, 5, 5, 5),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.18),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );

    final shaft = SizedBox(
      width: _shaftW,
      height: _shaftH,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF0B0E20),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12, width: 1.5),
              ),
            ),
          ),
          for (int f = 1; f <= 3; f++)
            Positioned(
              left: 8,
              right: 8,
              bottom: _levelBottom(f) - 3,
              height: 2,
              child: const ColoredBox(color: Colors.white12),
            ),
          // cable
          Positioned(
            left: _shaftW / 2 - 1,
            width: 2,
            top: 0,
            bottom: cabBottom + _cabH,
            child: const ColoredBox(color: Colors.white24),
          ),
          Positioned(
            left: _pad,
            width: _shaftW - 2 * _pad,
            bottom: cabBottom,
            height: _cabH,
            child: cabin,
          ),
        ],
      ),
    );

    final labels = SizedBox(
      width: 22,
      height: _shaftH,
      child: Stack(
        children: [
          for (int f = 1; f <= 3; f++)
            Positioned(
              left: 0,
              right: 0,
              bottom: _levelBottom(f) + _cabH / 2 - 10,
              child: Text(
                '$f',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: online && floor == f ? kGreen : Colors.white38,
                ),
              ),
            ),
        ],
      ),
    );

    final IconData arrow = !online
        ? Icons.remove_rounded
        : state == 'UP'
            ? Icons.arrow_upward_rounded
            : state == 'DOWN'
                ? Icons.arrow_downward_rounded
                : Icons.remove_rounded;

    final display = Container(
      width: 92,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0E20),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(arrow, size: 30, color: moving ? kGreen : Colors.white24),
          Text(
            online ? '$floor' : '–',
            style: TextStyle(
              fontSize: 56,
              height: 1.05,
              fontWeight: FontWeight.w800,
              color: online ? kGreen : Colors.white30,
            ),
          ),
        ],
      ),
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Opacity(
        opacity: online ? 1.0 : 0.55,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              labels,
              const SizedBox(width: 6),
              shaft,
              const SizedBox(width: 22),
              display,
            ],
          ),
        ),
      ),
    );
  }
}
