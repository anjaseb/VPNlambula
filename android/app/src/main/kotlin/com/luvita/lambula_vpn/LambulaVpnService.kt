package com.luvita.lambula_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.*
import java.net.*
import java.nio.ByteBuffer
import javax.net.ssl.SSLSocketFactory
import kotlin.concurrent.thread

class LambulaVpnService : VpnService() {

    companion object {
        const val ACTION_CONNECT = "ACTION_CONNECT"
        const val ACTION_DISCONNECT = "ACTION_DISCONNECT"
        const val CHANNEL_ID = "lambula_vpn_channel"
        const val TAG = "LambulaVPN"
        var eventCallback: ((String, Any?) -> Unit)? = null
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var running = false
    private var tunnelThread: Thread? = null
    private var proxySocket: Socket? = null

    // ── LIFECYCLE ───────────────────────────────────

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT -> {
                val config = extractConfig(intent)
                startForegroundNotification()
                connect(config)
            }
            ACTION_DISCONNECT -> disconnect()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        disconnect()
        super.onDestroy()
    }

    // ── CONFIG ──────────────────────────────────────

    data class VpnConfig(
        val host: String,
        val port: Int,
        val username: String,
        val password: String,
        val protocol: String,
        val uuid: String,
        val sni: String,
        val remoteDns: String,
        val payload: String,
        val injectMethod: String,
        val proxyUser: String,
        val proxyPass: String,
        val socksPort: Int,
        val keepalive: Int,
        val timeout: Int,
    )

    private fun extractConfig(intent: Intent) = VpnConfig(
        host         = intent.getStringExtra("host") ?: "",
        port         = intent.getIntExtra("port", 22),
        username     = intent.getStringExtra("username") ?: "",
        password     = intent.getStringExtra("password") ?: "",
        protocol     = intent.getStringExtra("protocol") ?: "SSH",
        uuid         = intent.getStringExtra("uuid") ?: "",
        sni          = intent.getStringExtra("sni") ?: "",
        remoteDns    = intent.getStringExtra("remoteDns") ?: "1.1.1.1",
        payload      = intent.getStringExtra("payload") ?: "",
        injectMethod = intent.getStringExtra("injectMethod") ?: "none",
        proxyUser    = intent.getStringExtra("proxyUser") ?: "",
        proxyPass    = intent.getStringExtra("proxyPass") ?: "",
        socksPort    = intent.getIntExtra("socksPort", 1080),
        keepalive    = intent.getIntExtra("keepalive", 30),
        timeout      = intent.getIntExtra("timeout", 15),
    )

    // ── CONNECT ─────────────────────────────────────

    private fun connect(config: VpnConfig) {
        tunnelThread = thread {
            try {
                sendLog("⚡ A iniciar túnel — método: ${config.injectMethod}")

                // Estabelecer socket conforme o método
                val socket = when (config.injectMethod) {
                    "ssl", "websocket-ssl", "ssh-over-ssl"
                        -> connectSsl(config)
                    "socks5", "socks5-auth"
                        -> connectSocks5(config)
                    "socks4"
                        -> connectSocks4(config)
                    "http-connect", "ssh-over-http", "http-proxy", "http-proxy-auth"
                        -> connectHttpConnect(config)
                    "http-inject", "http-inject-post", "http-inject-head"
                        -> connectHttpInject(config)
                    "websocket"
                        -> connectWebSocket(config)
                    "dns-tunnel"
                        -> connectDirect(config)
                    else
                        -> connectDirect(config)
                }

                proxySocket = socket
                protect(socket)
                sendLog("✅ Socket estabelecido")

                // Configurar interface VPN
                val vpnFd = buildVpnInterface(config)
                vpnInterface = vpnFd
                running = true

                // IP real obtido
                val remoteIp = try {
                    socket.inetAddress.hostAddress ?: config.host
                } catch (e: Exception) { config.host }

                sendEvent("onConnected", mapOf(
                    "ip" to remoteIp,
                    "location" to config.host,
                ))

                sendLog("🔒 VPN activa — a encaminhar tráfego")

                // Loop de encaminhamento
                startForwarding(vpnFd, socket, config)

            } catch (e: Exception) {
                Log.e(TAG, "Erro de conexão", e)
                sendLog("❌ Erro: ${e.message}")
                sendEvent("onError", e.message)
                cleanup()
            }
        }
    }

    // ── MÉTODOS DE CONEXÃO ──────────────────────────

    // 1. SSH / Directo
    private fun connectDirect(config: VpnConfig): Socket {
        sendLog("🔌 Conexão directa → ${config.host}:${config.port}")
        val socket = Socket()
        socket.soTimeout = config.timeout * 1000
        socket.connect(InetSocketAddress(config.host, config.port),
            config.timeout * 1000)
        sendLog("✅ Conexão directa estabelecida")
        return socket
    }

    // 2. SSL/TLS
    private fun connectSsl(config: VpnConfig): Socket {
        sendLog("🔒 Conexão SSL/TLS → ${config.host}:${config.port}")
        val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
        val sniHost = config.sni.ifEmpty { config.host }
        val socket = factory.createSocket(config.host, config.port) as javax.net.ssl.SSLSocket
        socket.soTimeout = config.timeout * 1000
        socket.enabledProtocols = arrayOf("TLSv1.2", "TLSv1.3")
        // SNI
        val params = socket.sslParameters
        params.serverNames = listOf(javax.net.ssl.SNIHostName(sniHost))
        socket.sslParameters = params
        socket.startHandshake()
        sendLog("✅ SSL handshake OK — SNI: $sniHost")
        return socket
    }

    // 3. HTTP CONNECT (payload customizado)
    private fun connectHttpConnect(config: VpnConfig): Socket {
        sendLog("🌐 HTTP CONNECT → ${config.host}:${config.port}")
        val socket = Socket()
        socket.soTimeout = config.timeout * 1000

        // Ligar à porta do payload (80/8080) ou directamente
        val connectPort = if (config.port == 22 &&
            config.injectMethod == "http-connect") 80 else config.port
        socket.connect(InetSocketAddress(config.host, connectPort),
            config.timeout * 1000)

        val out = socket.getOutputStream()
        val inp = BufferedReader(InputStreamReader(socket.getInputStream()))

        // Usar payload customizado ou padrão
        val rawPayload = if (config.payload.isNotEmpty()) {
            config.payload
        } else {
            "CONNECT ${config.host}:${config.port} HTTP/1.1\r\n" +
            "Host: ${config.host}\r\n" +
            "Proxy-Connection: Keep-Alive\r\n\r\n"
        }

        sendLog("📦 Payload:\n$rawPayload")
        out.write(rawPayload.toByteArray())
        out.flush()

        // Ler resposta
        val response = inp.readLine() ?: ""
        sendLog("📥 Resposta: $response")

        if (!response.contains("200")) {
            throw IOException("Proxy rejeitou: $response")
        }
        // Consumir cabeçalhos restantes
        var line = inp.readLine()
        while (!line.isNullOrEmpty()) {
            line = inp.readLine()
        }
        sendLog("✅ Túnel HTTP CONNECT estabelecido")
        return socket
    }

    // 4. HTTP Inject (GET/POST/HEAD)
    private fun connectHttpInject(config: VpnConfig): Socket {
        val method = when (config.injectMethod) {
            "http-inject-post" -> "POST"
            "http-inject-head" -> "HEAD"
            else -> "GET"
        }
        sendLog("💉 HTTP Inject $method → ${config.host}:${config.port}")
        val socket = Socket()
        socket.soTimeout = config.timeout * 1000
        socket.connect(InetSocketAddress(config.host, config.port),
            config.timeout * 1000)

        val out = socket.getOutputStream()
        val inp = BufferedReader(InputStreamReader(socket.getInputStream()))

        val rawPayload = if (config.payload.isNotEmpty()) {
            config.payload
        } else {
            "$method http://${config.host}:${config.port}/ HTTP/1.1\r\n" +
            "Host: ${config.host}\r\n" +
            "Connection: Keep-Alive\r\n\r\n"
        }

        sendLog("📦 Payload:\n$rawPayload")
        out.write(rawPayload.toByteArray())
        out.flush()

        val response = inp.readLine() ?: ""
        sendLog("📥 Resposta: $response")

        // HTTP Inject pode não retornar 200, continua mesmo assim
        if (response.contains("400") || response.contains("403")) {
            throw IOException("Inject rejeitado: $response")
        }
        sendLog("✅ HTTP Inject estabelecido")
        return socket
    }

    // 5. WebSocket
    private fun connectWebSocket(config: VpnConfig): Socket {
        sendLog("🔗 WebSocket → ${config.host}:${config.port}")
        val socket = Socket()
        socket.soTimeout = config.timeout * 1000
        socket.connect(InetSocketAddress(config.host, config.port),
            config.timeout * 1000)

        val out = socket.getOutputStream()
        val inp = BufferedReader(InputStreamReader(socket.getInputStream()))

        val sniHost = config.sni.ifEmpty { config.host }
        val key = android.util.Base64.encodeToString(
            ByteArray(16).also { java.security.SecureRandom().nextBytes(it) },
            android.util.Base64.NO_WRAP)

        val rawPayload = if (config.payload.isNotEmpty()) {
            config.payload
        } else {
            "GET / HTTP/1.1\r\n" +
            "Host: $sniHost\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: $key\r\n" +
            "Sec-WebSocket-Version: 13\r\n\r\n"
        }

        sendLog("📦 WS Handshake → $sniHost")
        out.write(rawPayload.toByteArray())
        out.flush()

        val response = inp.readLine() ?: ""
        sendLog("📥 Resposta: $response")

        if (!response.contains("101") && !response.contains("200")) {
            throw IOException("WebSocket rejeitado: $response")
        }
        var line = inp.readLine()
        while (!line.isNullOrEmpty()) line = inp.readLine()

        sendLog("✅ WebSocket estabelecido")
        return socket
    }

    // 6. SOCKS5
    private fun connectSocks5(config: VpnConfig): Socket {
        sendLog("🧦 SOCKS5 → ${config.host}:${config.port}")
        val socket = Socket()
        socket.soTimeout = config.timeout * 1000
        socket.connect(InetSocketAddress(config.host, config.port),
            config.timeout * 1000)

        val out = DataOutputStream(socket.getOutputStream())
        val inp = DataInputStream(socket.getInputStream())

        val useAuth = config.injectMethod == "socks5-auth" &&
            config.proxyUser.isNotEmpty()

        // Greeting
        if (useAuth) {
            out.write(byteArrayOf(0x05, 0x02, 0x00, 0x02))
        } else {
            out.write(byteArrayOf(0x05, 0x01, 0x00))
        }
        out.flush()

        val ver = inp.read()
        val method = inp.read()

        if (useAuth && method == 0x02) {
            // Autenticação
            val user = config.proxyUser.toByteArray()
            val pass = config.proxyPass.toByteArray()
            out.write(byteArrayOf(0x01,
                user.size.toByte(), *user,
                pass.size.toByte(), *pass))
            out.flush()
            inp.read(); inp.read() // ler resposta auth
            sendLog("✅ SOCKS5 auth OK")
        }

        // Pedido de conexão ao destino real
        val targetHost = config.sni.ifEmpty { config.host }
        val targetPort = 22
        val hostBytes = targetHost.toByteArray()
        out.write(byteArrayOf(0x05, 0x01, 0x00, 0x03,
            hostBytes.size.toByte(), *hostBytes))
        out.writeShort(targetPort)
        out.flush()

        // Ler resposta
        inp.read(); inp.read(); inp.read(); inp.read()
        val addrType = inp.read()
        when (addrType) {
            0x01 -> repeat(4) { inp.read() }
            0x03 -> repeat(inp.read()) { inp.read() }
            0x04 -> repeat(16) { inp.read() }
        }
        inp.readShort()

        sendLog("✅ SOCKS5 túnel estabelecido")
        return socket
    }

    // 7. SOCKS4
    private fun connectSocks4(config: VpnConfig): Socket {
        sendLog("🧦 SOCKS4 → ${config.host}:${config.port}")
        val socket = Socket()
        socket.soTimeout = config.timeout * 1000
        socket.connect(InetSocketAddress(config.host, config.port),
            config.timeout * 1000)

        val out = DataOutputStream(socket.getOutputStream())
        val inp = DataInputStream(socket.getInputStream())

        val targetIp = InetAddress.getByName(config.host).address
        out.write(byteArrayOf(0x04, 0x01))
        out.writeShort(22)
        out.write(targetIp)
        out.write(0x00)
        out.flush()

        inp.read(); val rep = inp.read()
        repeat(6) { inp.read() }

        if (rep != 0x5A) throw IOException("SOCKS4 rejeitado: $rep")
        sendLog("✅ SOCKS4 estabelecido")
        return socket
    }

    // ── INTERFACE VPN ───────────────────────────────

    private fun buildVpnInterface(config: VpnConfig): ParcelFileDescriptor {
        sendLog("🔧 A configurar interface VPN...")
        val dns = config.remoteDns.ifEmpty { "1.1.1.1" }
        return Builder()
            .setSession("Lambula VPN")
            .addAddress("10.0.0.2", 24)
            .addRoute("0.0.0.0", 0)
            .addDnsServer(dns)
            .addDnsServer("8.8.8.8")
            .setMtu(1500)
            .establish()
            ?: throw IOException("Falha ao criar interface VPN")
    }

    // ── FORWARDING ──────────────────────────────────

    private fun startForwarding(
        vpnFd: ParcelFileDescriptor,
        socket: Socket,
        config: VpnConfig
    ) {
        val vpnIn  = FileInputStream(vpnFd.fileDescriptor)
        val vpnOut = FileOutputStream(vpnFd.fileDescriptor)
        val sockOut = socket.getOutputStream()
        val sockIn  = socket.getInputStream()

        var bytesSent = 0L
        var bytesReceived = 0L

        // VPN → Servidor
        val toServer = thread {
            try {
                val buf = ByteArray(32768)
                while (running) {
                    val n = vpnIn.read(buf)
                    if (n > 0) {
                        sockOut.write(buf, 0, n)
                        sockOut.flush()
                        bytesSent += n
                    }
                }
            } catch (e: Exception) {
                if (running) sendLog("⚠️ Upstream: ${e.message}")
            }
        }

        // Servidor → VPN
        val toVpn = thread {
            try {
                val buf = ByteArray(32768)
                while (running) {
                    val n = sockIn.read(buf)
                    if (n > 0) {
                        vpnOut.write(buf, 0, n)
                        bytesReceived += n
                    } else if (n < 0) break
                }
            } catch (e: Exception) {
                if (running) sendLog("⚠️ Downstream: ${e.message}")
            }
        }

        // Keepalive + relatório de tráfego
        val keepaliveThread = thread {
            try {
                while (running) {
                    Thread.sleep(config.keepalive * 1000L)
                    sendEvent("onTraffic", mapOf(
                        "sent" to bytesSent,
                        "received" to bytesReceived,
                    ))
                    // Keepalive SSH
                    if (config.injectMethod == "none" ||
                        config.injectMethod == "ssh-direct") {
                        try {
                            sockOut.write(byteArrayOf())
                            sockOut.flush()
                        } catch (_: Exception) {}
                    }
                }
            } catch (_: InterruptedException) {}
        }

        toServer.join()
        toVpn.join()
        keepaliveThread.interrupt()

        if (running) {
            sendLog("⚠️ Conexão perdida — a desligar")
            sendEvent("onDisconnected", null)
            cleanup()
        }
    }

    // ── DISCONNECT ──────────────────────────────────

    private fun disconnect() {
        sendLog("🔓 A desligar VPN...")
        running = false
        cleanup()
        sendEvent("onDisconnected", null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun cleanup() {
        running = false
        try { proxySocket?.close() } catch (_: Exception) {}
        try { vpnInterface?.close() } catch (_: Exception) {}
        proxySocket = null
        vpnInterface = null
    }

    // ── NOTIFICAÇÃO ─────────────────────────────────

    private fun startForegroundNotification() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID, "Lambula VPN",
            NotificationManager.IMPORTANCE_LOW)
        manager.createNotificationChannel(channel)

        val intent = Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE)

        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Lambula VPN")
            .setContentText("VPN activa — LuVita")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()

        startForeground(1, notification)
    }

    // ── EVENTOS ─────────────────────────────────────

    private fun sendEvent(method: String, args: Any?) {
        eventCallback?.invoke(method, args)
    }

    private fun sendLog(msg: String) {
        Log.d(TAG, msg)
        eventCallback?.invoke("onLog", msg)
    }
}