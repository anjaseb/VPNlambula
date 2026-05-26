import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const LambulaApp());
}

// ─── MODELS ──────────────────────────────────────

class ServerConfig {
  final String id;
  final String name;
  final String country;
  final String countryCode;
  final String host;
  final int port;
  final String username;
  final String password;
  final String protocol;
  final String? uuid;
  final String? sni;
  final String? remoteDns;
  final String? payload;
  final String injectMethod;
  final String? proxyUser;
  final String? proxyPass;
  final int socksPort;
  final int keepalive;
  final int timeout;
  final int ping;
  final bool premium;
  final bool active;
  final String? expiry;

  ServerConfig({
    required this.id,
    required this.name,
    required this.country,
    required this.countryCode,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.protocol,
    this.uuid,
    this.sni,
    this.remoteDns,
    this.payload,
    required this.injectMethod,
    this.proxyUser,
    this.proxyPass,
    required this.socksPort,
    required this.keepalive,
    required this.timeout,
    required this.ping,
    required this.premium,
    required this.active,
    this.expiry,
  });

  factory ServerConfig.fromJson(Map<String, dynamic> j) => ServerConfig(
    id: j['id'] ?? '',
    name: j['name'] ?? '',
    country: j['country'] ?? 'Angola',
    countryCode: j['countryCode'] ?? 'AO',
    host: j['host'] ?? '',
    port: j['port'] ?? 22,
    username: j['username'] ?? '',
    password: j['password'] ?? '',
    protocol: j['protocol'] ?? 'SSH',
    uuid: j['uuid'],
    sni: j['sni'],
    remoteDns: j['remoteDns'],
    payload: j['payload'],
    injectMethod: j['injectMethod'] ?? 'none',
    proxyUser: j['proxyUser'],
    proxyPass: j['proxyPass'],
    socksPort: j['socksPort'] ?? 1080,
    keepalive: j['keepalive'] ?? 30,
    timeout: j['timeout'] ?? 15,
    ping: j['ping'] ?? 0,
    premium: j['premium'] ?? false,
    active: j['active'] ?? true,
    expiry: j['expiry'],
  );

  String get flagEmoji {
    if (countryCode.length != 2) return '';
    final base = 0x1F1E6 - 0x41;
    return String.fromCharCode(base + countryCode.codeUnitAt(0)) +
        String.fromCharCode(base + countryCode.codeUnitAt(1));
  }

  String get resolvedPayload {
    if (payload == null || payload!.isEmpty) return '';
    return payload!
        .replaceAll('[host]', host)
        .replaceAll('[port]', port.toString())
        .replaceAll('[sni]', sni ?? host)
        .replaceAll('[uuid]', uuid ?? '')
        .replaceAll('[auth]', proxyUser != null && proxyPass != null
            ? base64Encode(utf8.encode('$proxyUser:$proxyPass'))
            : '')
        .replaceAll('[crlf]', '\r\n');
  }
}

class AppConfig {
  final String appName;
  final String version;
  final String announcement;
  final Map<String, dynamic> globalOptions;
  final List<ServerConfig> servers;

  AppConfig({
    required this.appName,
    required this.version,
    required this.announcement,
    required this.globalOptions,
    required this.servers,
  });

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
    appName: j['appName'] ?? 'Lambula VPN',
    version: j['version'] ?? '1.0.0',
    announcement: j['announcement'] ?? '',
    globalOptions: j['globalOptions'] ?? {},
    servers: (j['servers'] as List? ?? [])
        .map((s) => ServerConfig.fromJson(s))
        .where((s) => s.active)
        .toList(),
  );
}

// ─── VPN STATUS ──────────────────────────────────

enum VpnStatus { disconnected, connecting, connected, reconnecting, error }

class VpnState {
  final VpnStatus status;
  final String? ip;
  final String? location;
  final int bytesSent;
  final int bytesReceived;
  final Duration duration;
  final String? error;
  final List<String> logs;
  final int retryCount;

  VpnState({
    this.status = VpnStatus.disconnected,
    this.ip,
    this.location,
    this.bytesSent = 0,
    this.bytesReceived = 0,
    this.duration = Duration.zero,
    this.error,
    this.logs = const [],
    this.retryCount = 0,
  });

  VpnState copyWith({
    VpnStatus? status,
    String? ip,
    String? location,
    int? bytesSent,
    int? bytesReceived,
    Duration? duration,
    String? error,
    List<String>? logs,
    int? retryCount,
  }) => VpnState(
    status: status ?? this.status,
    ip: ip ?? this.ip,
    location: location ?? this.location,
    bytesSent: bytesSent ?? this.bytesSent,
    bytesReceived: bytesReceived ?? this.bytesReceived,
    duration: duration ?? this.duration,
    error: error ?? this.error,
    logs: logs ?? this.logs,
    retryCount: retryCount ?? this.retryCount,
  );
}

// ─── CHANNEL ─────────────────────────────────────

const _channel = MethodChannel('com.luvita.lambula_vpn/vpn');

// ─── APP ─────────────────────────────────────────

class LambulaApp extends StatelessWidget {
  const LambulaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Lambula VPN',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF080E17),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF00C8F0),
        surface: Color(0xFF0C1420),
      ),
      fontFamily: 'sans-serif',
    ),
    home: const HomeScreen(),
  );
}

// ─── HOME SCREEN ─────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {

  AppConfig? _config;
  ServerConfig? _selectedServer;
  VpnState _vpn = VpnState();
  bool _loadingConfig = true;
  String? _configError;
  String? _announcement;

  // Reconexao
  Timer? _reconnectTimer;
  bool _userDisconnected = false;
  static const int _maxRetries = 5;
  static const List<int> _retryDelays = [5, 10, 20, 30, 60]; // segundos

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  Timer? _durationTimer;
  DateTime? _connectedAt;

  int _tab = 0;

  static const _configUrl =
      'https://raw.githubusercontent.com/anjaseb/VPNlambula/main/config.json';

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _loadConfig();
    _listenVpnChannel();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _durationTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }

  // ── CONFIG ──────────────────────────────────────

  Future<void> _loadConfig() async {
    setState(() {
      _loadingConfig = true;
      _configError = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final baseUrl = prefs.getString('config_url') ?? _configUrl;
      final ts = DateTime.now().millisecondsSinceEpoch;
      final url = '$baseUrl?nocache=$ts';

      final r = await http.get(Uri.parse(url), headers: {
        'Cache-Control': 'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
      }).timeout(const Duration(seconds: 15));

      if (r.statusCode == 200) {
        late AppConfig cfg;
        try {
          cfg = AppConfig.fromJson(jsonDecode(r.body));
        } catch (_) {
          setState(() {
            _loadingConfig = false;
            _configError = 'Formato invalido no config.json';
          });
          return;
        }
        setState(() {
          _config = cfg;
          _announcement = cfg.announcement.isNotEmpty ? cfg.announcement : null;
          if (_selectedServer != null) {
            final still = cfg.servers.any((s) => s.id == _selectedServer!.id);
            if (!still) _selectedServer = cfg.servers.isNotEmpty ? cfg.servers.first : null;
          } else if (cfg.servers.isNotEmpty) {
            _selectedServer = cfg.servers.first;
          }
          _loadingConfig = false;
        });
        _addLog('[CONFIG] ${cfg.servers.length} servidor(es) carregado(s)');
      } else {
        throw Exception('HTTP ${r.statusCode}');
      }
    } on TimeoutException {
      setState(() {
        _loadingConfig = false;
        _configError = 'Tempo esgotado. Verifica a ligacao.';
      });
    } catch (e) {
      setState(() {
        _loadingConfig = false;
        _configError = 'Sem ligacao ao repositorio.';
      });
    }
  }

  // ── VPN CHANNEL ─────────────────────────────────

  void _listenVpnChannel() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onConnected':
          _onConnected(call.arguments as Map?);
          break;
        case 'onDisconnected':
          _onDisconnected();
          break;
        case 'onError':
          _onVpnError(call.arguments.toString());
          break;
        case 'onLog':
          _addLog(call.arguments.toString());
          break;
        case 'onTraffic':
          final args = call.arguments as Map?;
          if (args != null) {
            setState(() {
              _vpn = _vpn.copyWith(
                bytesSent: args['sent'] ?? _vpn.bytesSent,
                bytesReceived: args['received'] ?? _vpn.bytesReceived,
              );
            });
          }
          break;
      }
    });
  }

  void _onConnected(Map? args) {
    _reconnectTimer?.cancel();
    _connectedAt = DateTime.now();
    setState(() {
      _vpn = _vpn.copyWith(
        status: VpnStatus.connected,
        ip: args?['ip'] ?? '--',
        location: args?['location'],
        retryCount: 0,
      );
    });
    _addLog('[VPN] Conectado. IP: ${_vpn.ip}');
    _startDurationTimer();
  }

  void _onDisconnected() {
    _connectedAt = null;
    _durationTimer?.cancel();
    // Se o utilizador desligou manualmente, nao reconecta
    if (_userDisconnected) {
      setState(() { _vpn = VpnState(); });
      _addLog('[VPN] Desligado pelo utilizador.');
      return;
    }
    // Reconexao automatica
    _scheduleReconnect();
  }

  void _onVpnError(String msg) {
    _addLog('[ERRO] $msg');
    if (!_userDisconnected) {
      _scheduleReconnect();
    } else {
      setState(() {
        _vpn = _vpn.copyWith(status: VpnStatus.error, error: msg);
      });
    }
  }

  // ── RECONEXAO AUTOMATICA ─────────────────────────

  void _scheduleReconnect() {
    final retries = _vpn.retryCount;
    if (retries >= _maxRetries) {
      setState(() {
        _vpn = _vpn.copyWith(
          status: VpnStatus.error,
          error: 'Falhou apos $_maxRetries tentativas.',
        );
      });
      _addLog('[VPN] Maximo de tentativas atingido. Liga manualmente.');
      return;
    }

    final delay = _retryDelays[retries.clamp(0, _retryDelays.length - 1)];
    setState(() {
      _vpn = _vpn.copyWith(
        status: VpnStatus.reconnecting,
        retryCount: retries + 1,
      );
    });
    _addLog('[VPN] A reconectar em ${delay}s... (tentativa ${retries + 1}/$_maxRetries)');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (!mounted || _userDisconnected) return;
      _addLog('[VPN] A tentar reconectar...');
      _connectServer(_selectedServer!);
    });
  }

  // ── CONNECT / DISCONNECT ────────────────────────

  Future<void> _toggleVpn() async {
    if (_vpn.status == VpnStatus.connected ||
        _vpn.status == VpnStatus.connecting ||
        _vpn.status == VpnStatus.reconnecting) {
      _userDisconnected = true;
      _reconnectTimer?.cancel();
      await _disconnect();
    } else {
      _userDisconnected = false;
      await _connect();
    }
  }

  Future<void> _connect() async {
    if (_selectedServer == null) {
      _showSnack('Selecciona um servidor primeiro');
      return;
    }
    final perm = await _channel.invokeMethod('requestVpnPermission');
    if (perm != true) {
      _showSnack('Permissao VPN negada');
      return;
    }
    setState(() {
      _vpn = _vpn.copyWith(status: VpnStatus.connecting, retryCount: 0);
    });
    await _connectServer(_selectedServer!);
  }

  Future<void> _connectServer(ServerConfig s) async {
    _addLog('[VPN] A conectar a ${s.name} (${s.host}:${s.port})');
    _addLog('[VPN] Metodo: ${s.injectMethod}');
    if (s.sni != null && s.sni!.isNotEmpty) _addLog('[VPN] SNI: ${s.sni}');
    try {
      await _channel.invokeMethod('connect', {
        'host': s.host,
        'port': s.port,
        'username': s.username,
        'password': s.password,
        'protocol': s.protocol,
        'uuid': s.uuid,
        'sni': s.sni,
        'remoteDns': s.remoteDns ?? '1.1.1.1',
        'payload': s.resolvedPayload,
        'injectMethod': s.injectMethod,
        'proxyUser': s.proxyUser,
        'proxyPass': s.proxyPass,
        'socksPort': s.socksPort,
        'keepalive': s.keepalive,
        'timeout': s.timeout,
      });
    } catch (e) {
      _onVpnError(e.toString());
    }
  }

  Future<void> _disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (e) {
      setState(() { _vpn = VpnState(); });
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_connectedAt != null && mounted) {
        setState(() {
          _vpn = _vpn.copyWith(
            duration: DateTime.now().difference(_connectedAt!));
        });
      }
    });
  }

  // ── HELPERS ─────────────────────────────────────

  void _addLog(String msg) {
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2,'0')}:'
               '${t.minute.toString().padLeft(2,'0')}:'
               '${t.second.toString().padLeft(2,'0')}';
    if (!mounted) return;
    setState(() {
      final logs = List<String>.from(_vpn.logs);
      logs.insert(0, '[$ts] $msg');
      if (logs.length > 200) logs.removeLast();
      _vpn = _vpn.copyWith(logs: logs);
    });
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFF0C1420)));
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)}MB';
  }

  String _formatDuration(Duration d) =>
      '${d.inHours.toString().padLeft(2,'0')}:'
      '${(d.inMinutes % 60).toString().padLeft(2,'0')}:'
      '${(d.inSeconds % 60).toString().padLeft(2,'0')}';

  Color get _statusColor {
    switch (_vpn.status) {
      case VpnStatus.connected:     return const Color(0xFF00E5A0);
      case VpnStatus.connecting:    return const Color(0xFFFFB347);
      case VpnStatus.reconnecting:  return const Color(0xFFFFB347);
      case VpnStatus.error:         return const Color(0xFFFF4D6D);
      case VpnStatus.disconnected:  return const Color(0xFF4A7A9B);
    }
  }

  String get _statusText {
    switch (_vpn.status) {
      case VpnStatus.connected:    return 'LIGADO';
      case VpnStatus.connecting:   return 'A LIGAR...';
      case VpnStatus.reconnecting: return 'A RECONECTAR...';
      case VpnStatus.error:        return 'ERRO';
      case VpnStatus.disconnected: return 'DESLIGADO';
    }
  }

  bool get _isBusy =>
      _vpn.status == VpnStatus.connecting ||
      _vpn.status == VpnStatus.reconnecting;

  // ─── BUILD ───────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080E17),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            if (_announcement != null) _buildAnnouncement(),
            _buildTabs(),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  _buildHomeTab(),
                  _buildServersTab(),
                  _buildLogsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── TOP BAR ─────────────────────────────────────

  Widget _buildTopBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      color: const Color(0xFF080E17),
      border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.07))),
    ),
    child: Row(
      children: [
        _buildLogo(),
        const Spacer(),
        _loadingConfig
            ? const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF00C8F0)))
            : IconButton(
                icon: const Icon(Icons.refresh, color: Color(0xFF4A7A9B), size: 20),
                onPressed: _loadConfig,
                tooltip: 'Actualizar',
              ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () => launchUrl(
            Uri.parse('https://facebook.com'),
            mode: LaunchMode.externalApplication,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1877F2).withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF1877F2).withOpacity(0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.facebook, color: Color(0xFF1877F2), size: 16),
                SizedBox(width: 6),
                Text('LuVita', style: TextStyle(
                  color: Color(0xFF1877F2), fontSize: 12,
                  fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildLogo() => Row(
    children: [
      CustomPaint(size: const Size(32, 32), painter: _FishPainter()),
      const SizedBox(width: 10),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('LAMBULA VPN', style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w800,
            letterSpacing: 2, color: Colors.white)),
          Text('by LuVita', style: TextStyle(
            fontSize: 10, color: Colors.white.withOpacity(0.4),
            letterSpacing: 1)),
        ],
      ),
    ],
  );

  // ── ANNOUNCEMENT ────────────────────────────────

  Widget _buildAnnouncement() => Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFF00C8F0).withOpacity(0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFF00C8F0).withOpacity(0.2)),
    ),
    child: Row(
      children: [
        Expanded(child: Text(_announcement!,
          style: const TextStyle(fontSize: 12, color: Color(0xFF00C8F0)))),
        GestureDetector(
          onTap: () => setState(() => _announcement = null),
          child: Icon(Icons.close, size: 16,
            color: const Color(0xFF00C8F0).withOpacity(0.6)),
        ),
      ],
    ),
  );

  // ── TABS ────────────────────────────────────────

  Widget _buildTabs() => Container(
    decoration: BoxDecoration(
      color: const Color(0xFF0C1420),
      border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.07))),
    ),
    child: Row(children: [
      _tabItem(0, 'INICIO'),
      _tabItem(1, 'SERVIDORES'),
      _tabItem(2, 'LOGS'),
    ]),
  );

  Widget _tabItem(int i, String label) {
    final active = _tab == i;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = i),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(
              color: active ? const Color(0xFF00C8F0) : Colors.transparent,
              width: 2,
            )),
          ),
          child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5,
              color: active
                  ? const Color(0xFF00C8F0)
                  : Colors.white.withOpacity(0.35),
            )),
        ),
      ),
    );
  }

  // ── HOME TAB ────────────────────────────────────

  Widget _buildHomeTab() => SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Column(
      children: [
        _buildConnectButton(),
        const SizedBox(height: 24),
        _buildStatusCard(),
        const SizedBox(height: 16),
        _buildTrafficCard(),
        const SizedBox(height: 16),
        if (_selectedServer != null) _buildSelectedServerCard(),
        if (_configError != null) ...[
          const SizedBox(height: 16),
          _buildErrorCard(),
        ],
        // Banner de reconexao
        if (_vpn.status == VpnStatus.reconnecting) ...[
          const SizedBox(height: 16),
          _buildReconnectBanner(),
        ],
      ],
    ),
  );

  Widget _buildReconnectBanner() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFFFB347).withOpacity(0.08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFFFB347).withOpacity(0.25)),
    ),
    child: Row(
      children: [
        const SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2, color: Color(0xFFFFB347))),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Tentativa ${_vpn.retryCount}/$_maxRetries — A reconectar automaticamente...',
            style: const TextStyle(
              color: Color(0xFFFFB347), fontSize: 12)),
        ),
        GestureDetector(
          onTap: () {
            _userDisconnected = true;
            _reconnectTimer?.cancel();
            setState(() { _vpn = VpnState(); });
          },
          child: const Text('CANCELAR',
            style: TextStyle(
              color: Color(0xFFFF4D6D), fontSize: 11,
              fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );

  Widget _buildErrorCard() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFFF4D6D).withOpacity(0.08),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFFFF4D6D).withOpacity(0.2)),
    ),
    child: Column(
      children: [
        Text(_configError!,
          style: const TextStyle(color: Color(0xFFFF4D6D), fontSize: 12),
          textAlign: TextAlign.center),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: _loadConfig,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFF4D6D).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFF4D6D).withOpacity(0.3)),
            ),
            child: const Text('TENTAR NOVAMENTE',
              style: TextStyle(color: Color(0xFFFF4D6D),
                fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    ),
  );

  Widget _buildConnectButton() {
    final isConnected = _vpn.status == VpnStatus.connected;
    return GestureDetector(
      onTap: _toggleVpn,
      child: AnimatedBuilder(
        animation: _pulseAnim,
        builder: (_, __) => Transform.scale(
          scale: _isBusy ? _pulseAnim.value : 1.0,
          child: Container(
            width: 160, height: 160,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0C1420),
              border: Border.all(color: _statusColor, width: 2.5),
              boxShadow: [
                BoxShadow(color: _statusColor.withOpacity(0.3),
                  blurRadius: 30, spreadRadius: 5),
              ],
            ),
            child: _isBusy
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 40, height: 40,
                        child: CircularProgressIndicator(
                          strokeWidth: 3, color: _statusColor)),
                      const SizedBox(height: 10),
                      Text(_statusText,
                        style: TextStyle(
                          color: _statusColor, fontSize: 10,
                          fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isConnected ? Icons.lock : Icons.lock_open,
                        color: _statusColor, size: 48),
                      const SizedBox(height: 8),
                      Text(_statusText,
                        style: TextStyle(
                          color: _statusColor, fontSize: 11,
                          fontWeight: FontWeight.w800, letterSpacing: 2)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() => _card(
    child: Row(children: [
      _statItem('IP', _vpn.ip ?? '--', const Color(0xFF00C8F0)),
      _divider(),
      _statItem('TEMPO', _formatDuration(_vpn.duration), const Color(0xFF00E5A0)),
      _divider(),
      _statItem('ESTADO', _statusText, _statusColor),
    ]),
  );

  Widget _buildTrafficCard() => _card(
    child: Row(children: [
      _statItem('ENVIADO', _formatBytes(_vpn.bytesSent), const Color(0xFFFFB347)),
      _divider(),
      _statItem('RECEBIDO', _formatBytes(_vpn.bytesReceived), const Color(0xFF00E5A0)),
    ]),
  );

  Widget _buildSelectedServerCard() {
    final s = _selectedServer!;
    return _card(
      child: Row(
        children: [
          // Bandeira sem texto adicional
          Text(s.flagEmoji, style: const TextStyle(fontSize: 28)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(s.name,
              style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 15)),
          ),
          if (s.premium)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFFFB347).withOpacity(0.12),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: const Color(0xFFFFB347).withOpacity(0.3)),
              ),
              child: const Text('PRO',
                style: TextStyle(
                  color: Color(0xFFFFB347), fontSize: 10,
                  fontWeight: FontWeight.w800)),
            ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => setState(() => _tab = 1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF00C8F0).withOpacity(0.08),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: const Color(0xFF00C8F0).withOpacity(0.2)),
              ),
              child: const Text('TROCAR',
                style: TextStyle(
                  color: Color(0xFF00C8F0), fontSize: 11,
                  fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  // ── SERVERS TAB ─────────────────────────────────

  Widget _buildServersTab() {
    if (_loadingConfig) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF00C8F0)),
            SizedBox(height: 16),
            Text('A carregar servidores...',
              style: TextStyle(color: Color(0xFF4A7A9B), fontSize: 12)),
          ],
        ),
      );
    }

    if (_configError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cloud_off,
                color: Colors.white.withOpacity(0.15), size: 48),
              const SizedBox(height: 16),
              Text(_configError!,
                style: TextStyle(color: Colors.white.withOpacity(0.4),
                  fontSize: 13),
                textAlign: TextAlign.center),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: _loadConfig,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00C8F0).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF00C8F0).withOpacity(0.3)),
                  ),
                  child: const Text('TENTAR NOVAMENTE',
                    style: TextStyle(
                      color: Color(0xFF00C8F0), fontSize: 12,
                      fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_config == null || _config!.servers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.dns_outlined, color: Colors.white.withOpacity(0.15), size: 48),
            const SizedBox(height: 16),
            Text('Sem servidores disponiveis',
              style: TextStyle(color: Colors.white.withOpacity(0.4))),
            const SizedBox(height: 6),
            Text('Adiciona servidores no painel admin',
              style: TextStyle(
                color: Colors.white.withOpacity(0.2), fontSize: 11)),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _loadConfig,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF00C8F0).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF00C8F0).withOpacity(0.3)),
                ),
                child: const Text('ACTUALIZAR',
                  style: TextStyle(
                    color: Color(0xFF00C8F0), fontSize: 12,
                    fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _config!.servers.length,
      itemBuilder: (_, i) {
        final s = _config!.servers[i];
        final selected = _selectedServer?.id == s.id;
        return GestureDetector(
          onTap: () {
            setState(() {
              _selectedServer = s;
              _tab = 0;
            });
            _showSnack('${s.name} seleccionado');
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF00C8F0).withOpacity(0.06)
                  : const Color(0xFF0C1420),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? const Color(0xFF00C8F0)
                    : Colors.white.withOpacity(0.07),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                // Apenas bandeira e nome — sem mais nada
                Text(s.flagEmoji,
                  style: const TextStyle(fontSize: 26)),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(s.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15,
                      color: Colors.white)),
                ),
                if (s.premium)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFB347).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: const Color(0xFFFFB347).withOpacity(0.25)),
                    ),
                    child: const Text('PRO',
                      style: TextStyle(
                        fontSize: 9, fontWeight: FontWeight.w800,
                        color: Color(0xFFFFB347))),
                  ),
                const SizedBox(width: 8),
                Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected
                      ? const Color(0xFF00C8F0)
                      : Colors.white.withOpacity(0.2),
                  size: 20),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── LOGS TAB ────────────────────────────────────

  Widget _buildLogsTab() => Column(
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Text('LOGS DE CONEXAO',
              style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 2,
                color: Colors.white.withOpacity(0.4), fontFamily: 'monospace')),
            const Spacer(),
            GestureDetector(
              onTap: () => setState(() {
                _vpn = _vpn.copyWith(logs: []);
              }),
              child: const Text('LIMPAR',
                style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w700,
                  letterSpacing: 1.5, color: Color(0xFF00C8F0))),
            ),
          ],
        ),
      ),
      Expanded(
        child: _vpn.logs.isEmpty
            ? Center(child: Text('Sem logs',
                style: TextStyle(color: Colors.white.withOpacity(0.2))))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _vpn.logs.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(_vpn.logs[i],
                    style: const TextStyle(
                      fontSize: 11, fontFamily: 'monospace',
                      color: Color(0xFF00E5A0), height: 1.5)),
                ),
              ),
      ),
    ],
  );

  // ── WIDGETS HELPERS ─────────────────────────────

  Widget _card({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF0C1420),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white.withOpacity(0.07)),
    ),
    child: child,
  );

  Widget _statItem(String label, String value, Color color) => Expanded(
    child: Column(
      children: [
        Text(label, style: TextStyle(
          fontSize: 9, letterSpacing: 1.5,
          color: Colors.white.withOpacity(0.35), fontFamily: 'monospace')),
        const SizedBox(height: 4),
        Text(value,
          style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w800,
            color: color, fontFamily: 'monospace'),
          overflow: TextOverflow.ellipsis),
      ],
    ),
  );

  Widget _divider() => Container(
    width: 1, height: 32, color: Colors.white.withOpacity(0.07));
}

// ─── FISH PAINTER ────────────────────────────────

class _FishPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * 0.52;
    final cy = size.height * 0.50;

    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2), size.width / 2,
      Paint()..color = const Color(0xFF020B18));

    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy),
        width: size.width * 0.76, height: size.height * 0.44),
      Paint()..color = const Color(0xFF0D7EC2));

    final tail = Path()
      ..moveTo(cx - size.width * 0.38, cy)
      ..lineTo(cx - size.width * 0.60, cy - size.height * 0.20)
      ..lineTo(cx - size.width * 0.46, cy)
      ..lineTo(cx - size.width * 0.60, cy + size.height * 0.20)
      ..close();
    canvas.drawPath(tail, Paint()..color = const Color(0xFF0A4F8C));

    canvas.drawCircle(
      Offset(cx + size.width * 0.24, cy - size.height * 0.06),
      size.width * 0.08, Paint()..color = const Color(0xFFEAF6FF));
    canvas.drawCircle(
      Offset(cx + size.width * 0.24, cy - size.height * 0.06),
      size.width * 0.04, Paint()..color = const Color(0xFF020B18));
  }

  @override
  bool shouldRepaint(_) => false;
}
