import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const SmartElevatorApp());

const kBg = Color(0xFF0F1226);
const kCard = Color(0xFF1B1F3B);
const kAccent = Color(0xFF6C63FF);
const kGreen = Color(0xFF2ED8A3);
const kRed = Color(0xFFFF5C7A);

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

class _HomePageState extends State<HomePage> {
  BluetoothConnection? _conn;
  bool get connected => _conn?.isConnected ?? false;
  bool _connecting = false;
  String _typed = '';

  Future<void> _send(String msg) async {
    if (!connected) {
      _toast('Not connected');
      return;
    }
    try {
      _conn!.output.add(Uint8List.fromList(utf8.encode(msg)));
      await _conn!.output.allSent;
      _toast('Sent: $msg');
    } catch (_) {
      _toast('Send failed');
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 1)));

  Future<void> _onConnectTap() async {
    if (connected) {
      await _conn?.close();
      if (mounted) setState(() => _conn = null);
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
      c.input?.listen((_) {}).onDone(() {
        if (mounted) setState(() => _conn = null);
      });
      if (mounted) setState(() => _conn = c);
    } catch (_) {
      _toast('Connection failed');
      if (mounted) setState(() => _conn = null);
    }
    if (mounted) setState(() => _connecting = false);
  }

  void _key(String k) {
    if (k == 'OK') {
      _send('OK');
      setState(() => _typed = '');
    } else if (k == 'Delete') {
      _send('Delete');
      if (_typed.isNotEmpty) setState(() => _typed = _typed.substring(0, _typed.length - 1));
    } else {
      _send(k);
      if (_typed.length < 8) setState(() => _typed += k);
    }
  }

  @override
  void dispose() {
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
              const SizedBox(height: 28),
              // Title
              const Icon(Icons.elevator_rounded, size: 44, color: kAccent),
              const SizedBox(height: 8),
              const Text('Smart Elevator',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 1)),
              const SizedBox(height: 28),
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
            _send('floor $n');
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
