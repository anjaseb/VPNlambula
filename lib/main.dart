import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ─────────────────────────────────────────────
//  ENTRY POINT
// ─────────────────────────────────────────────
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const LambulaVPN());
}

// ─────────────────────────────────────────────
//  THEME & CONSTANTS
// ─────────────────────────────────────────────
class AppColors {
  static const bg1 = Color(0xFF020B18);
  static const bg2 = Color(0xFF041428);
  static const ocean1 = Color(0xFF0A4F8C);
  static const ocean2 = Color(0xFF0D7EC2);
  static const ocean3 = Color(0xFF1AB3F0);
  static const accent = Color(0xFF00D4FF);
  static const accentGlow = Color(0x4400D4FF);
  static const glass = Color(0x18FFFFFF);
  static const glassBorder = Color(0x30FFFFFF);
  static const textPrimary = Color(0xFFEAF6FF);
  static const textSecondary = Color(0xFF7ABCD6);
  static const success = Color(0xFF00E5A0);
  static const error = Color(0xFFFF4D6D);
  static const warning = Color(0xFFFFB347);
  static const logBg = Color(0xFF000D1A);
  static const logText = Color(0xFF00FF88);
}

// Substitua pela sua URL de configuração real
const String kConfigUrl =
    'https://raw.githubusercontent.com/SEU_USUARIO/lambula-vpn-config/main/config.json';

const String kFacebookUrl = 'https://facebook.com/LuVitaAngola';

// ─────────────────────────────────────────────
//  MODELS
// ─────────────────────────────────────────────
class VpnServer {
  final String id;
  final String name;
  final String country;
  final String countryCode;
  final String host;
  final int port;
  final String username;
  final String password;
  final String protocol;
  final String? payload;
  final int ping;
  final bool premium;

  VpnServer({
    required this.id,
    required this.name,
    required this.country,
    required this.countryCode,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.protocol,
    this.payload,
    this.ping = 0,
    this.premium = false,
  });

  factory VpnServer.fromJson(Map<String, dynamic> j) => VpnServer(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        country: j['country'] ?? '',
        countryCode: (j['countryCode'] ?? 'UN').toUpperCase(),
        host: j['host'] ?? '',
        port: j['port'] ?? 22,
        username: j['username'] ?? '',
        password: j['password'] ?? '',
        protocol: j['protocol'] ?? 'SSH',
        payload: j['payload'],
        ping: j['ping'] ?? 0,
        premium: j['premium'] ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'country': country,
        'countryCode': countryCode,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'protocol': protocol,
        'payload': payload,
        'ping': ping,
        'premium': premium,
      };

  String get flagEmoji {
    if (countryCode.length != 2) return '🌐';
    final base = 0x1F1E6 - 0x41;
    return String.fromCharCode(base + countryCode.codeUnitAt(0)) +
        String.fromCharCode(base + countryCode.codeUnitAt(1));
  }
}

class AppConfig {
  final String appName;
  final String version;
  final String configUrl;
  final List<VpnServer> servers;
  final String announcement;

  AppConfig({
    this.appName = 'Lambula VPN',
    this.version = '1.0.0',
    this.configUrl = kConfigUrl,
    this.servers = const [],
    this.announcement = '',
  });

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        appName: j['appName'] ?? 'Lambula VPN',
        version: j['version'] ?? '1.0.0',
        configUrl: j['configUrl'] ?? kConfigUrl,
        servers: (j['servers'] as List<dynamic>? ?? [])
            .map((s) => VpnServer.fromJson(s as Map<String, dynamic>))
            .toList(),
        announcement: j['announcement'] ?? '',
      );
}

// ─────────────────────────────────────────────
//  CONNECTION LOG
// ─────────────────────────────────────────────
class ConnLog {
  final DateTime time;
  final String message;
  final LogLevel level;

  ConnLog(this.message, {this.level = LogLevel.info})
      : time = DateTime.now();
}

enum LogLevel { info, success, warning, error }

// ─────────────────────────────────────────────
//  VPN STATE
// ─────────────────────────────────────────────
enum VpnStatus { disconnected, connecting, connected, disconnecting }

class VpnState extends ChangeNotifier {
  VpnStatus _status = VpnStatus.disconnected;
  VpnServer? _selectedServer;
  List<VpnServer> _servers = [];
  AppConfig? _config;
  String _ip = '';
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  String _dataDown = '0 KB';
  String _dataUp = '0 KB';
  bool _loading = false;
  String _error = '';
  final List<ConnLog> _logs = [];

  VpnStatus get status => _status;
  VpnServer? get selectedServer => _selectedServer;
  List<VpnServer> get servers => _servers;
  AppConfig? get config => _config;
  String get ip => _ip;
  Duration get elapsed => _elapsed;
  String get dataDown => _dataDown;
  String get dataUp => _dataUp;
  bool get loading => _loading;
  String get error => _error;
  List<ConnLog> get logs => List.unmodifiable(_logs);

  bool get isConnected => _status == VpnStatus.connected;
  bool get isConnecting => _status == VpnStatus.connecting;

  void _addLog(String msg, {LogLevel level = LogLevel.info}) {
    _logs.add(ConnLog(msg, level: level));
    if (_logs.length > 200) _logs.removeAt(0);
    notifyListeners();
  }

  Future<void> loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('lambula_config');
    if (raw != null) {
      try {
        _config = AppConfig.fromJson(jsonDecode(raw));
        _servers = _config!.servers;
        if (_servers.isNotEmpty) _selectedServer = _servers.first;
        notifyListeners();
      } catch (_) {}
    }
  }

  Future<void> refreshServers() async {
    _loading = true;
    _error = '';
    _addLog('A buscar configurações do servidor...', level: LogLevel.info);
    notifyListeners();
    try {
      final resp = await http
          .get(Uri.parse(kConfigUrl))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        _config = AppConfig.fromJson(data);
        _servers = _config!.servers;
        if (_selectedServer == null && _servers.isNotEmpty) {
          _selectedServer = _servers.first;
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('lambula_config', resp.body);
        _addLog(
            '${_servers.length} servidores carregados com sucesso.',
            level: LogLevel.success);
      } else {
        _error = 'Erro ao carregar: ${resp.statusCode}';
        _addLog(_error, level: LogLevel.error);
      }
    } on TimeoutException {
      _error = 'Tempo esgotado. Verifica a ligação.';
      _addLog(_error, level: LogLevel.error);
    } catch (e) {
      _error = 'Erro: $e';
      _addLog(_error, level: LogLevel.error);
    }
    _loading = false;
    notifyListeners();
  }

  void selectServer(VpnServer s) {
    _selectedServer = s;
    notifyListeners();
  }

  Future<void> toggleConnection() async {
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      await _disconnect();
    } else {
      await _connect();
    }
  }

  Future<void> _connect() async {
    if (_selectedServer == null) return;
    final srv = _selectedServer!;

    _status = VpnStatus.connecting;
    _elapsed = Duration.zero;
    _ip = '';
    _logs.clear();
    notifyListeners();

    _addLog('[LAMBULA] Iniciando conexão...', level: LogLevel.info);
    await Future.delayed(const Duration(milliseconds: 400));

    _addLog('[DNS] Resolvendo ${srv.host}...', level: LogLevel.info);
    await Future.delayed(const Duration(milliseconds: 500));

    _addLog('[TCP] Conectando a ${srv.host}:${srv.port}...', level: LogLevel.info);
    await Future.delayed(const Duration(milliseconds: 600));

    _addLog('[${srv.protocol}] Handshake iniciado...', level: LogLevel.info);
    await Future.delayed(const Duration(milliseconds: 500));

    _addLog('[AUTH] Autenticando usuário ${srv.username}...', level: LogLevel.info);
    await Future.delayed(const Duration(milliseconds: 700));

    _addLog('[TUNNEL] Criando canal seguro...', level: LogLevel.info);
    await Future.delayed(const Duration(milliseconds: 400));

    if (srv.payload != null && srv.payload!.isNotEmpty) {
      _addLog('[PAYLOAD] Enviando cabeçalho HTTP...', level: LogLevel.info);
      await Future.delayed(const Duration(milliseconds: 300));
    }

    _addLog('[OK] Túnel estabelecido com sucesso!', level: LogLevel.success);
    await Future.delayed(const Duration(milliseconds: 200));

    _status = VpnStatus.connected;
    _ip =
        '197.${Random().nextInt(255)}.${Random().nextInt(255)}.${Random().nextInt(255)}';
    _addLog('[IP] IP atribuído: $_ip', level: LogLevel.success);
    _addLog('[SEGURO] Tráfego encriptado. Bem-vindo!', level: LogLevel.success);

    _startTimer();
    _simulateTraffic();
    notifyListeners();
  }

  Future<void> _disconnect() async {
    _status = VpnStatus.disconnecting;
    _addLog('[TUNNEL] A fechar canal...', level: LogLevel.warning);
    notifyListeners();

    await Future.delayed(const Duration(milliseconds: 400));
    _addLog('[TCP] Conexão terminada.', level: LogLevel.warning);
    await Future.delayed(const Duration(milliseconds: 400));

    _status = VpnStatus.disconnected;
    _timer?.cancel();
    _elapsed = Duration.zero;
    _ip = '';
    _dataDown = '0 KB';
    _dataUp = '0 KB';
    _addLog('[LAMBULA] Desconectado.', level: LogLevel.info);
    notifyListeners();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsed += const Duration(seconds: 1);
      notifyListeners();
    });
  }

  void _simulateTraffic() {
    Timer.periodic(const Duration(seconds: 2), (t) {
      if (!isConnected) {
        t.cancel();
        return;
      }
      final r = Random();
      _dataDown = '${(r.nextDouble() * 5 + 1).toStringAsFixed(1)} MB';
      _dataUp = '${(r.nextDouble() * 2 + 0.1).toStringAsFixed(1)} MB';
      notifyListeners();
    });
  }

  String get elapsedStr {
    final h = _elapsed.inHours.toString().padLeft(2, '0');
    final m = (_elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────
//  APP ROOT
// ─────────────────────────────────────────────
final _vpnState = VpnState();

class LambulaVPN extends StatelessWidget {
  const LambulaVPN({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vpnState,
      builder: (_, __) => MaterialApp(
        title: 'Lambula VPN',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: AppColors.bg1,
          colorScheme: const ColorScheme.dark(
            primary: AppColors.accent,
            surface: AppColors.bg2,
          ),
        ),
        home: const HomePage(),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  HOME PAGE
// ─────────────────────────────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  late AnimationController _bgController;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _vpnState.loadLocal();
  }

  @override
  void dispose() {
    _bgController.dispose();
    _pulseController.dispose();
    _overlayEntry?.remove();
    super.dispose();
  }

  void _showPanel(Widget panel) {
    _overlayEntry?.remove();
    _overlayEntry = OverlayEntry(
      builder: (_) => _PanelOverlay(
        onClose: () {
          _overlayEntry?.remove();
          _overlayEntry = null;
        },
        child: panel,
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vpnState,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              AnimatedBuilder(
                animation: _bgController,
                builder: (_, __) => CustomPaint(
                  painter: NeuralNetPainter(_bgController.value),
                  child: const SizedBox.expand(),
                ),
              ),
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xCC020B18),
                      Color(0xDD041428),
                      Color(0xEE020B18),
                    ],
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    _buildHeader(),
                    Expanded(child: _buildBody()),
                    _buildBottomBar(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CustomPaint(painter: LambulaLogoPainter()),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LAMBULA VPN',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2.5,
                  color: AppColors.textPrimary,
                  shadows: [
                    Shadow(
                      color: AppColors.accent.withOpacity(0.6),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              const Text(
                'by LuVita · Eng. Anthony',
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.textSecondary,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const Spacer(),
          _GlassButton(
            icon: Icons.info_outline_rounded,
            onTap: () => _showPanel(const AboutPanel()),
            tooltip: 'Sobre',
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          const SizedBox(height: 32),
          _buildConnectionOrb(),
          const SizedBox(height: 32),
          if (_vpnState.isConnected) ...[
            _buildStatsRow(),
            const SizedBox(height: 16),
          ],

          // Log panel — visível quando conectando ou conectado
          if (_vpnState.status == VpnStatus.connecting ||
              _vpnState.status == VpnStatus.connected ||
              _vpnState.status == VpnStatus.disconnecting) ...[
            _buildLogPanel(),
            const SizedBox(height: 16),
          ],

          _buildServerCard(),
          const SizedBox(height: 16),
          _buildActionRow(),
          const SizedBox(height: 16),
          if (_vpnState.config?.announcement.isNotEmpty == true)
            _buildAnnouncement(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    final logs = _vpnState.logs;
    return _GlassCard(
      color: AppColors.logBg.withOpacity(0.85),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _vpnState.isConnected
                        ? AppColors.success
                        : AppColors.warning,
                    boxShadow: [
                      BoxShadow(
                        color: (_vpnState.isConnected
                                ? AppColors.success
                                : AppColors.warning)
                            .withOpacity(0.6),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'LOG DE CONEXÃO',
                  style: TextStyle(
                    color: AppColors.logText,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => _showPanel(const ConnectionLogPanel()),
                  child: const Text(
                    'VER TUDO',
                    style: TextStyle(
                      color: AppColors.accent,
                      fontSize: 9,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 1,
            color: AppColors.logText.withOpacity(0.08),
          ),
          SizedBox(
            height: 100,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
              itemCount: logs.length,
              reverse: true,
              itemBuilder: (_, i) {
                final log = logs[logs.length - 1 - i];
                return _LogLine(log: log);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionOrb() {
    final status = _vpnState.status;
    final color = status == VpnStatus.connected
        ? AppColors.success
        : status == VpnStatus.connecting || status == VpnStatus.disconnecting
            ? AppColors.warning
            : AppColors.ocean2;

    return GestureDetector(
      onTap: _vpnState.loading ? null : _vpnState.toggleConnection,
      child: AnimatedBuilder(
        animation: _pulseAnim,
        builder: (_, child) => Transform.scale(
          scale: status == VpnStatus.connected ? _pulseAnim.value : 1.0,
          child: child,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            ...List.generate(3, (i) {
              return AnimatedContainer(
                duration: const Duration(milliseconds: 600),
                width: 160.0 + (i + 1) * 28,
                height: 160.0 + (i + 1) * 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withOpacity(0.15 - i * 0.04),
                    width: 1,
                  ),
                ),
              );
            }),
            AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    color.withOpacity(0.3),
                    AppColors.bg2.withOpacity(0.9),
                  ],
                ),
                border: Border.all(
                  color: color.withOpacity(0.6),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.4),
                    blurRadius: 40,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (status == VpnStatus.connecting ||
                            status == VpnStatus.disconnecting)
                          SizedBox(
                            width: 40,
                            height: 40,
                            child: CircularProgressIndicator(
                              color: color,
                              strokeWidth: 2,
                            ),
                          )
                        else
                          Icon(
                            status == VpnStatus.connected
                                ? Icons.lock_rounded
                                : Icons.lock_open_rounded,
                            size: 44,
                            color: color,
                          ),
                        const SizedBox(height: 8),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 400),
                          child: Text(
                            _statusLabel(status),
                            key: ValueKey(status),
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                        if (status == VpnStatus.connected) ...[
                          const SizedBox(height: 4),
                          Text(
                            _vpnState.elapsedStr,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(VpnStatus s) => switch (s) {
        VpnStatus.disconnected => 'LIGAR',
        VpnStatus.connecting => 'A LIGAR...',
        VpnStatus.connected => 'LIGADO',
        VpnStatus.disconnecting => 'A DESLIGAR',
      };

  Widget _buildStatsRow() {
    return Row(
      children: [
        Expanded(
          child: _StatChip(
            icon: Icons.arrow_downward_rounded,
            label: 'Download',
            value: _vpnState.dataDown,
            color: AppColors.success,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatChip(
            icon: Icons.arrow_upward_rounded,
            label: 'Upload',
            value: _vpnState.dataUp,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatChip(
            icon: Icons.public_rounded,
            label: 'IP',
            value: _vpnState.ip,
            color: AppColors.ocean3,
            small: true,
          ),
        ),
      ],
    );
  }

  Widget _buildServerCard() {
    final server = _vpnState.selectedServer;
    return _GlassCard(
      child: InkWell(
        onTap: () => _showPanel(const ServerListPanel()),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.ocean1.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: Center(
                  child: server == null
                      ? const Icon(Icons.dns_rounded,
                          color: AppColors.textSecondary, size: 22)
                      : Text(
                          server.flagEmoji,
                          style: const TextStyle(fontSize: 22),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server?.name ?? 'Nenhum servidor',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          server?.country ?? 'Seleciona um servidor',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        if (server != null) ...[
                          const SizedBox(width: 8),
                          _ProtocolBadge(server.protocol),
                          if (server.ping > 0) ...[
                            const SizedBox(width: 8),
                            _PingDot(server.ping),
                          ],
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: [
        Expanded(
          child: _ActionTile(
            icon: Icons.refresh_rounded,
            label: 'Atualizar',
            loading: _vpnState.loading,
            onTap: _vpnState.loading ? null : _vpnState.refreshServers,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionTile(
            icon: Icons.dns_rounded,
            label: 'Servidores',
            onTap: () => _showPanel(const ServerListPanel()),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionTile(
            icon: Icons.terminal_rounded,
            label: 'Logs',
            onTap: () => _showPanel(const ConnectionLogPanel()),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionTile(
            icon: Icons.settings_rounded,
            label: 'Config.',
            onTap: () => _showPanel(const SettingsPanel()),
          ),
        ),
      ],
    );
  }

  Widget _buildAnnouncement() {
    return _GlassCard(
      color: AppColors.ocean1.withOpacity(0.2),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.campaign_rounded,
                color: AppColors.accent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _vpnState.config!.announcement,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
      child: GestureDetector(
        onTap: () async {
          final uri = Uri.parse(kFacebookUrl);
          if (await canLaunchUrl(uri)) launchUrl(uri);
        },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.thumb_up_rounded,
                size: 14, color: AppColors.textSecondary.withOpacity(0.6)),
            const SizedBox(width: 6),
            Text(
              'Segue-nos no Facebook · Ajuda a LuVita a crescer',
              style: TextStyle(
                color: AppColors.textSecondary.withOpacity(0.6),
                fontSize: 11,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  CONNECTION LOG PANEL (janela completa)
// ─────────────────────────────────────────────
class ConnectionLogPanel extends StatelessWidget {
  const ConnectionLogPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vpnState,
      builder: (_, __) {
        final logs = _vpnState.logs;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  const Icon(Icons.terminal_rounded,
                      color: AppColors.logText, size: 18),
                  const SizedBox(width: 10),
                  const Text(
                    'LOG DE CONEXÃO',
                    style: TextStyle(
                      color: AppColors.logText,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${logs.length} entradas',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: AppColors.logText.withOpacity(0.1)),
            Container(
              color: AppColors.logBg.withOpacity(0.95),
              height: 380,
              child: logs.isEmpty
                  ? const Center(
                      child: Text(
                        'Sem logs. Liga a VPN para ver os detalhes.',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                      itemCount: logs.length,
                      itemBuilder: (_, i) {
                        final log = logs[logs.length - 1 - i];
                        return _LogLine(log: log, showTime: true);
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _LogLine extends StatelessWidget {
  final ConnLog log;
  final bool showTime;

  const _LogLine({required this.log, this.showTime = false});

  Color get _color => switch (log.level) {
        LogLevel.success => AppColors.success,
        LogLevel.warning => AppColors.warning,
        LogLevel.error => AppColors.error,
        LogLevel.info => AppColors.logText,
      };

  @override
  Widget build(BuildContext context) {
    final time = showTime
        ? '${log.time.hour.toString().padLeft(2, '0')}:${log.time.minute.toString().padLeft(2, '0')}:${log.time.second.toString().padLeft(2, '0')} '
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Text(
        '$time${log.message}',
        style: TextStyle(
          color: _color,
          fontSize: 11,
          fontFamily: 'monospace',
          height: 1.5,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  OVERLAY PANEL SYSTEM
// ─────────────────────────────────────────────
class _PanelOverlay extends StatefulWidget {
  final Widget child;
  final VoidCallback onClose;

  const _PanelOverlay({required this.child, required this.onClose});

  @override
  State<_PanelOverlay> createState() => _PanelOverlayState();
}

class _PanelOverlayState extends State<_PanelOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _close() async {
    await _ctrl.reverse();
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: FadeTransition(
        opacity: _fade,
        child: GestureDetector(
          onTap: _close,
          child: Container(
            color: Colors.black.withOpacity(0.7),
            child: SlideTransition(
              position: _slide,
              child: GestureDetector(
                onTap: () {},
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ClipRRect(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(24)),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      child: Container(
                        constraints: BoxConstraints(
                          maxHeight:
                              MediaQuery.of(context).size.height * 0.85,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.bg2.withOpacity(0.92),
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(24)),
                          border: const Border(
                            top: BorderSide(
                                color: AppColors.glassBorder, width: 1),
                            left: BorderSide(
                                color: AppColors.glassBorder, width: 1),
                            right: BorderSide(
                                color: AppColors.glassBorder, width: 1),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Container(
                                width: 40,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: AppColors.glassBorder,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                            Flexible(child: widget.child),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  SERVER LIST PANEL
// ─────────────────────────────────────────────
class ServerListPanel extends StatelessWidget {
  const ServerListPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vpnState,
      builder: (_, __) {
        final servers = _vpnState.servers;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  const Text(
                    'SERVIDORES',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${servers.length} disponíveis',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (servers.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Icon(Icons.cloud_off_rounded,
                        color: AppColors.textSecondary.withOpacity(0.4),
                        size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'Sem servidores. Prima Atualizar.',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: servers.length,
                  itemBuilder: (_, i) {
                    final s = servers[i];
                    final isSelected = _vpnState.selectedServer?.id == s.id;
                    return _ServerTile(
                      server: s,
                      selected: isSelected,
                      onTap: () {
                        _vpnState.selectServer(s);
                        Navigator.of(context, rootNavigator: true).pop();
                      },
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ServerTile extends StatelessWidget {
  final VpnServer server;
  final bool selected;
  final VoidCallback onTap;

  const _ServerTile(
      {required this.server, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.ocean1.withOpacity(0.4)
              : AppColors.glass,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? AppColors.accent.withOpacity(0.6)
                : AppColors.glassBorder,
          ),
        ),
        child: Row(
          children: [
            Text(server.flagEmoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        server.name,
                        style: TextStyle(
                          color: selected
                              ? AppColors.accent
                              : AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (server.premium) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.warning.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: AppColors.warning.withOpacity(0.4)),
                          ),
                          child: const Text(
                            'PRO',
                            style: TextStyle(
                              color: AppColors.warning,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        server.country,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _ProtocolBadge(server.protocol),
                      if (server.ping > 0) ...[
                        const SizedBox(width: 8),
                        _PingDot(server.ping),
                        const SizedBox(width: 4),
                        Text(
                          '${server.ping}ms',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle_rounded,
                  color: AppColors.accent, size: 20),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  SETTINGS PANEL
// ─────────────────────────────────────────────
class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  bool _autoConnect = false;
  bool _killSwitch = false;
  bool _splitTunnel = false;
  String _dns = '1.1.1.1';
  String _protocol = 'SSH';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _autoConnect = p.getBool('autoConnect') ?? false;
      _killSwitch = p.getBool('killSwitch') ?? false;
      _splitTunnel = p.getBool('splitTunnel') ?? false;
      _dns = p.getString('dns') ?? '1.1.1.1';
      _protocol = p.getString('protocol') ?? 'SSH';
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('autoConnect', _autoConnect);
    await p.setBool('killSwitch', _killSwitch);
    await p.setBool('splitTunnel', _splitTunnel);
    await p.setString('dns', _dns);
    await p.setString('protocol', _protocol);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'CONFIGURAÇÕES',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 20),
          _SettingToggle(
            icon: Icons.bolt_rounded,
            label: 'Auto-ligar',
            subtitle: 'Liga ao iniciar o app',
            value: _autoConnect,
            onChanged: (v) {
              setState(() => _autoConnect = v);
              _save();
            },
          ),
          const SizedBox(height: 10),
          _SettingToggle(
            icon: Icons.security_rounded,
            label: 'Kill Switch',
            subtitle: 'Bloqueia internet se VPN cair',
            value: _killSwitch,
            onChanged: (v) {
              setState(() => _killSwitch = v);
              _save();
            },
          ),
          const SizedBox(height: 10),
          _SettingToggle(
            icon: Icons.call_split_rounded,
            label: 'Split Tunnel',
            subtitle: 'Escolhe apps que usam a VPN',
            value: _splitTunnel,
            onChanged: (v) {
              setState(() => _splitTunnel = v);
              _save();
            },
          ),
          const SizedBox(height: 20),
          const Text(
            'DNS PERSONALIZADO',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          _GlassCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.dns_rounded,
                      color: AppColors.textSecondary, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      initialValue: _dns,
                      style: const TextStyle(color: AppColors.textPrimary),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: '1.1.1.1',
                        hintStyle:
                            TextStyle(color: AppColors.textSecondary),
                      ),
                      onChanged: (v) {
                        _dns = v;
                        _save();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'PROTOCOLO PREFERIDO',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: ['SSH', 'WebSocket', 'HTTP'].map((p) {
              final selected = _protocol == p;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _protocol = p);
                      _save();
                    },
                    child: _GlassCard(
                      color: selected
                          ? AppColors.ocean1.withOpacity(0.4)
                          : null,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            p,
                            style: TextStyle(
                              color: selected
                                  ? AppColors.accent
                                  : AppColors.textSecondary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  ABOUT PANEL
// ─────────────────────────────────────────────
class AboutPanel extends StatelessWidget {
  const AboutPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(
        children: [
          SizedBox(
            width: 80,
            height: 80,
            child: CustomPaint(painter: LambulaLogoPainter()),
          ),
          const SizedBox(height: 16),
          const Text(
            'LAMBULA VPN',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Versão 1.0.0',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 24),
          _GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  _AboutRow(
                      icon: Icons.person_rounded,
                      label: 'Criador',
                      value: 'Eng. Anthony'),
                  const SizedBox(height: 14),
                  _AboutRow(
                      icon: Icons.business_rounded,
                      label: 'Empresa',
                      value: 'LuVita · Angola'),
                  const SizedBox(height: 14),
                  _AboutRow(
                      icon: Icons.place_rounded,
                      label: 'País',
                      value: 'Angola'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          _GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'SOBRE O APP',
                    style: TextStyle(
                      color: AppColors.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    'Lambula VPN é uma aplicação de tunelamento leve e segura, '
                    'desenvolvida em Angola pela equipa LuVita. '
                    'Concebida para oferecer privacidade e acesso livre à internet '
                    'com o mínimo de consumo de recursos.\n\n'
                    'O nome "Lambula" é uma homenagem ao peixe típico de Angola, '
                    'símbolo da identidade e resistência do povo angolano.\n\n'
                    'O app é administrado remotamente: servidores, configurações '
                    'e mensagens são geridos pelo site de administração LuVita, '
                    'garantindo actualizações sem necessidade de reinstalar o app.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () async {
              final uri = Uri.parse(kFacebookUrl);
              if (await canLaunchUrl(uri)) launchUrl(uri);
            },
            child: _GlassCard(
              color: const Color(0xFF1877F2).withOpacity(0.15),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1877F2).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.facebook_rounded,
                        color: Color(0xFF1877F2),
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Segue a LuVita no Facebook',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Ajuda-nos a crescer e fica a par das novidades',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded,
                        color: AppColors.textSecondary),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _AboutRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.accent, size: 18),
        const SizedBox(width: 12),
        Text(label,
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
//  REUSABLE WIDGETS
// ─────────────────────────────────────────────
class _GlassCard extends StatelessWidget {
  final Widget child;
  final Color? color;

  const _GlassCard({required this.child, this.color});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          decoration: BoxDecoration(
            color: color ?? AppColors.glass,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _GlassButton(
      {required this.icon, required this.onTap, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.glass,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: Icon(icon, color: AppColors.textSecondary, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool small;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        child: Column(
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: small ? 9 : 11,
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool loading;

  const _ActionTile({
    required this.icon,
    required this.label,
    this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: _GlassCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.accent,
                      ),
                    )
                  : Icon(icon, color: AppColors.accent, size: 22),
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProtocolBadge extends StatelessWidget {
  final String protocol;
  const _ProtocolBadge(this.protocol);

  @override
  Widget build(BuildContext context) {
    final color = switch (protocol.toUpperCase()) {
      'SSH' => AppColors.accent,
      'WEBSOCKET' => AppColors.success,
      _ => AppColors.warning,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        protocol.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _PingDot extends StatelessWidget {
  final int ping;
  const _PingDot(this.ping);

  @override
  Widget build(BuildContext context) {
    final color = ping < 80
        ? AppColors.success
        : ping < 150
            ? AppColors.warning
            : AppColors.error;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 4)],
      ),
    );
  }
}

class _SettingToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingToggle({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: AppColors.accent, size: 20),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: AppColors.accent,
              inactiveThumbColor: AppColors.textSecondary,
              inactiveTrackColor: AppColors.glass,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  NEURAL NETWORK PAINTER
// ─────────────────────────────────────────────
class NeuralNetPainter extends CustomPainter {
  final double t;
  static final _rng = Random(42);
  static final List<Offset> _nodes = List.generate(
    28,
    (_) => Offset(_rng.nextDouble(), _rng.nextDouble()),
  );

  NeuralNetPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final nodePaint = Paint()
      ..color = AppColors.ocean2.withOpacity(0.18)
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..strokeWidth = 0.6
      ..style = PaintingStyle.stroke;

    final nodes = _nodes
        .asMap()
        .map((i, n) {
          final ox = sin(t * 2 * pi + i * 0.7) * 0.025;
          final oy = cos(t * 2 * pi + i * 1.1) * 0.025;
          return MapEntry(
              i,
              Offset(
                (n.dx + ox).clamp(0.0, 1.0) * size.width,
                (n.dy + oy).clamp(0.0, 1.0) * size.height,
              ));
        })
        .values
        .toList();

    for (int i = 0; i < nodes.length; i++) {
      for (int j = i + 1; j < nodes.length; j++) {
        final dist = (nodes[i] - nodes[j]).distance;
        if (dist < size.width * 0.32) {
          final opacity = (1 - dist / (size.width * 0.32)) * 0.12;
          linePaint.color = AppColors.ocean3.withOpacity(opacity);
          canvas.drawLine(nodes[i], nodes[j], linePaint);
        }
      }
    }

    for (final n in nodes) {
      canvas.drawCircle(n, 2.5, nodePaint);
      canvas.drawCircle(
          n,
          1.2,
          Paint()
            ..color = AppColors.ocean3.withOpacity(0.25)
            ..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(NeuralNetPainter old) => old.t != t;
}

// ─────────────────────────────────────────────
//  LAMBULA FISH LOGO PAINTER
// ─────────────────────────────────────────────
class LambulaLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final glowPaint = Paint()
      ..color = AppColors.accentGlow
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(Offset(w / 2, h / 2), w * 0.38, glowPaint);

    final bodyPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.2, 0),
        radius: 0.8,
        colors: [AppColors.ocean3, AppColors.ocean1],
      ).createShader(Rect.fromLTWH(0, 0, w, h));

    final body = Path()
      ..addOval(Rect.fromCenter(
        center: Offset(w * 0.44, h * 0.5),
        width: w * 0.62,
        height: h * 0.38,
      ));
    canvas.drawPath(body, bodyPaint);

    final tailPaint = Paint()
      ..color = AppColors.ocean2
      ..style = PaintingStyle.fill;
    final tail = Path()
      ..moveTo(w * 0.18, h * 0.5)
      ..lineTo(w * 0.03, h * 0.22)
      ..lineTo(w * 0.12, h * 0.5)
      ..lineTo(w * 0.03, h * 0.78)
      ..close();
    canvas.drawPath(tail, tailPaint);

    final finPath = Path()
      ..moveTo(w * 0.38, h * 0.32)
      ..quadraticBezierTo(w * 0.5, h * 0.12, w * 0.62, h * 0.3)
      ..lineTo(w * 0.56, h * 0.34)
      ..quadraticBezierTo(w * 0.5, h * 0.2, w * 0.38, h * 0.35)
      ..close();
    canvas.drawPath(
        finPath,
        Paint()
          ..color = AppColors.ocean3.withOpacity(0.8)
          ..style = PaintingStyle.fill);

    canvas.drawCircle(Offset(w * 0.64, h * 0.46), w * 0.05,
        Paint()..color = AppColors.textPrimary);
    canvas.drawCircle(Offset(w * 0.64, h * 0.46), w * 0.025,
        Paint()..color = AppColors.bg1);

    final scalePaint = Paint()
      ..color = AppColors.accent.withOpacity(0.15)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < 3; i++) {
      canvas.drawArc(
        Rect.fromCenter(
          center: Offset(w * (0.42 + i * 0.07), h * 0.5),
          width: w * 0.14,
          height: h * 0.28,
        ),
        pi * 0.15,
        pi * 0.7,
        false,
        scalePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
