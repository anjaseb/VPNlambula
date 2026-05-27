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
import java.nio.channels.FileChannel
import java.nio.channels.Selector
import java.nio.channels.SelectionKey
import java.nio.channels.SocketChannel
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLParameters
import kotlin.concurrent.thread

class LambulaVpnService : VpnService() {

    companion object {
        const val ACTION_CONNECT    = "ACTION_CONNECT"
        const val ACTION_DISCONNECT = "ACTION_DISCONNECT"
        const val CHANNEL_ID        = "lambula_vpn_channel"
        const val TAG               = "LambulaVPN"
        var eventCallback: ((String, Any?) -> Unit)? = null
    }

    private var vpnInterface : ParcelFileDescriptor? = null
    private var running      = false
    private var tunnelThread : Thread? = null
    private var proxySocket  : Socket? = null
    private var socksServer  : ServerSocket? = null

    // ── LIFECYCLE ───────────────────────────────────

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT    -> { startForegroundNotification(); connect(extractConfig(intent)) }
            ACTION_DISCONNECT -> disconnect()
        }
        return START_STICKY
    }

    override fun onDestroy() { disconnect(); super.onDestroy() }

    // ── CONFIG ──────────────────────────────────────

    data class VpnConfig(
        val host: String, val port: Int,
        val username: String, val password: String,
        val protocol: String, val uuid: String,
        val sni: String, val remoteDns: String,
        val payload: String, val injectMethod: String,
        val proxyUser: String, val proxyPass: String,
        val socksPort: Int, val keepalive: Int, val timeout: Int,
    )

    private fun extractConfig(i: Intent) = VpnConfig(
        host         = i.getStringExtra("host")         ?: "",
        port         = i.getIntExtra("port", 22),
        username     = i.getStringExtra("username")     ?: "",
        password     = i.getStringExtra("password")     ?: "",
        protocol     = i.getStringExtra("protocol")     ?: "SSH",
        uuid         = i.getStringExtra("uuid")         ?: "",
        sni          = i.getStringExtra("sni")          ?: "",
        remoteDns    = i.getStringExtra("remoteDns")    ?: "1.1.1.1",
        payload      = i.getStringExtra("payload")      ?: "",
        injectMethod = i.getStringExtra("injectMethod") ?: "none",
        proxyUser    = i.getStringExtra("proxyUser")    ?: "",
        proxyPass    = i.getStringExtra("proxyPass")    ?: "",
        socksPort    = i.getIntExtra("socksPort", 1080),
        keepalive    = i.getIntExtra("keepalive", 30),
        timeout      = i.getIntExtra("timeout", 15),
    )

    // ── CONNECT ─────────────────────────────────────

    private fun connect(config: VpnConfig) {
        tunnelThread = thread {
            try {
                sendLog("[VPN] A iniciar tunel — metodo: ${config.injectMethod}")

                // 1. Criar socket e proteger ANTES de ligar
                val socket = Socket()
                protect(socket)

                // 2. Ligar conforme o metodo
                val tunnelSocket = when (config.injectMethod) {
                    "ssl", "websocket-ssl", "ssh-over-ssl"
                        -> connectSsl(socket, config)
                    "socks5", "socks5-auth"
                        -> connectSocks5(socket, config)
                    "socks4"
                        -> connectSocks4(socket, config)
                    "http-connect", "ssh-over-http", "http-proxy", "http-proxy-auth"
                        -> connectHttpConnect(socket, config)
                    "http-inject", "http-inject-post", "http-inject-head"
                        -> connectHttpInject(socket, config)
                    "websocket"
                        -> connectWebSocket(socket, config)
                    else
                        -> connectDirect(socket, config)
                }

                proxySocket = tunnelSocket
                sendLog("[VPN] Socket estabelecido com sucesso")

                // 3. Construir interface VPN
                val vpnFd = buildVpnInterface(config)
                vpnInterface = vpnFd
                running = true

                // 4. IP remoto real
                val remoteIp = try {
                    tunnelSocket.inetAddress?.hostAddress ?: config.host
                } catch (e: Exception) { config.host }

                sendEvent("onConnected", mapOf("ip" to remoteIp, "location" to config.host))
                sendLog("[VPN] Activa — IP: $remoteIp")

                // 5. Iniciar proxy SOCKS5 local + forwarding
                startLocalProxy(vpnFd, tunnelSocket, config)

            } catch (e: Exception) {
                Log.e(TAG, "Erro de conexao", e)
                sendLog("[ERRO] ${e.message}")
                sendEvent("onError", e.message)
                cleanup()
            }
        }
    }

    // ── METODOS DE CONEXAO ──────────────────────────

    // 1. Directo (SSH puro)
    private fun connectDirect(socket: Socket, config: VpnConfig): Socket {
        sendLog("[CONN] Conexao directa -> ${config.host}:${config.port}")
        socket.connect(InetSocketAddress(config.host, config.port), config.timeout * 1000)
        sendLog("[CONN] Conexao directa estabelecida")
        return socket
    }

    // 2. SSL/TLS com SNI
    private fun connectSsl(socket: Socket, config: VpnConfig): Socket {
        sendLog("[CONN] SSL/TLS -> ${config.host}:${config.port}")
        socket.connect(InetSocketAddress(config.host, config.port), config.timeout * 1000)
        val sniHost = config.sni.ifEmpty { config.host }
        val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
        val ssl = factory.createSocket(socket, sniHost, config.port, true) as SSLSocket
        ssl.soTimeout = 0 // sem timeout no forwarding
        val params = SSLParameters()
        params.serverNames = listOf(javax.net.ssl.SNIHostName(sniHost))
        ssl.sslParameters = params
        ssl.startHandshake()
        sendLog("[CONN] SSL OK — SNI: $sniHost")
        return ssl
    }

    // 3. HTTP CONNECT com payload customizado
    private fun connectHttpConnect(socket: Socket, config: VpnConfig): Socket {
        val connectPort = when {
            config.payload.contains(":443") -> 443
            config.payload.contains(":8080") -> 8080
            config.port != 22 -> config.port
            else -> 80
        }
        sendLog("[CONN] HTTP CONNECT -> ${config.host}:$connectPort")
        socket.connect(InetSocketAddress(config.host, connectPort), config.timeout * 1000)
        socket.soTimeout = config.timeout * 1000

        val out = socket.getOutputStream()
        val inp = socket.getInputStream()
        val reader = BufferedReader(InputStreamReader(inp))

        val rawPayload = if (config.payload.isNotEmpty()) {
            config.payload
        } else {
            "CONNECT ${config.host}:${config.port} HTTP/1.1\r\n" +
            "Host: ${config.host}\r\n" +
            "Proxy-Connection: Keep-Alive\r\n\r\n"
        }

        sendLog("[CONN] Payload enviado")
        out.write(rawPayload.toByteArray(Charsets.ISO_8859_1))
        out.flush()

        val response = reader.readLine() ?: throw IOException("Sem resposta do proxy")
        sendLog("[CONN] Resposta: $response")

        if (!response.contains("200")) throw IOException("Proxy rejeitou: $response")

        // Consumir cabecalhos restantes
        var line = reader.readLine()
        while (!line.isNullOrEmpty()) line = reader.readLine()

        socket.soTimeout = 0 // remover timeout para forwarding
        sendLog("[CONN] Tunel HTTP CONNECT estabelecido")
        return socket
    }

    // 4. HTTP Inject GET/POST/HEAD
    private fun connectHttpInject(socket: Socket, config: VpnConfig): Socket {
        val method = when (config.injectMethod) {
            "http-inject-post" -> "POST"
            "http-inject-head" -> "HEAD"
            else -> "GET"
        }
        sendLog("[CONN] HTTP Inject $method -> ${config.host}:${config.port}")
        socket.connect(InetSocketAddress(config.host, config.port), config.timeout * 1000)
        socket.soTimeout = config.timeout * 1000

        val out = socket.getOutputStream()
        val reader = BufferedReader(InputStreamReader(socket.getInputStream()))

        val rawPayload = if (config.payload.isNotEmpty()) {
            config.payload
        } else {
            "$method http://${config.host}:${config.port}/ HTTP/1.1\r\n" +
            "Host: ${config.host}\r\n" +
            "Connection: Keep-Alive\r\n\r\n"
        }

        sendLog("[CONN] Payload enviado")
        out.write(rawPayload.toByteArray(Charsets.ISO_8859_1))
        out.flush()

        val response = reader.readLine() ?: ""
        sendLog("[CONN] Resposta: $response")
        if (response.contains("400") || response.contains("403"))
            throw IOException("Inject rejeitado: $response")

        socket.soTimeout = 0
        sendLog("[CONN] HTTP Inject estabelecido")
        return socket
    }

    // 5. WebSocket
    private fun connectWebSocket(socket: Socket, config: VpnConfig): Socket {
        sendLog("[CONN] WebSocket -> ${config.host}:${config.port}")
        socket.connect(InetSocketAddress(config.host, config.port), config.timeout * 1000)
        socket.soTimeout = config.timeout * 1000

        val out = socket.getOutputStream()
        val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
        val sniHost = config.sni.ifEmpty { config.host }

        val key = android.util.Base64.encodeToString(
            ByteArray(16).also { java.security.SecureRandom().nextBytes(it) },
            android.util.Base64.NO_WRAP)

        val rawPayload = if (config.payload.isNotEmpty()) {
            config.payload
        } else {
            "GET / HTTP/1.1\r\nHost: $sniHost\r\nUpgrade: websocket\r\n" +
            "Connection: Upgrade\r\nSec-WebSocket-Key: $key\r\n" +
            "Sec-WebSocket-Version: 13\r\n\r\n"
        }

        sendLog("[CONN] WS Handshake -> $sniHost")
        out.write(rawPayload.toByteArray(Charsets.ISO_8859_1))
        out.flush()

        val response = reader.readLine() ?: ""
        sendLog("[CONN] Resposta: $response")
        if (!response.contains("101") && !response.contains("200"))
            throw IOException("WebSocket rejeitado: $response")

        var line = reader.readLine()
        while (!line.isNullOrEmpty()) line = reader.readLine()

        socket.soTimeout = 0
        sendLog("[CONN] WebSocket estabelecido")
        return socket
    }

    // 6. SOCKS5
    private fun connectSocks5(socket: Socket, config: VpnConfig): Socket {
        sendLog("[CONN] SOCKS5 -> ${config.host}:${config.port}")
        socket.connect(InetSocketAddress(config.host, config.port), config.timeout * 1000)
        socket.soTimeout = config.timeout * 1000

        val out = DataOutputStream(socket.getOutputStream())
        val inp = DataInputStream(socket.getInputStream())
        val useAuth = config.injectMethod == "socks5-auth" && config.proxyUser.isNotEmpty()

        if (useAuth) out.write(byteArrayOf(0x05, 0x02, 0x00, 0x02))
        else         out.write(byteArrayOf(0x05, 0x01, 0x00))
        out.flush()

        inp.read() // VER
        val method = inp.read()

        if (useAuth && method == 0x02) {
            val user = config.proxyUser.toByteArray()
            val pass = config.proxyPass.toByteArray()
            out.write(byteArrayOf(0x01, user.size.toByte(), *user, pass.size.toByte(), *pass))
            out.flush()
            inp.read(); inp.read()
            sendLog("[CONN] SOCKS5 auth OK")
        }

        // Destino real — usa a porta correcta do config
        val targetHost = config.sni.ifEmpty { config.host }
        val targetPort = config.port
        val hostBytes = targetHost.toByteArray()
        out.write(byteArrayOf(0x05, 0x01, 0x00, 0x03, hostBytes.size.toByte(), *hostBytes))
        out.writeShort(targetPort)
        out.flush()

        inp.read(); inp.read(); inp.read()
        val addrType = inp.read()
        when (addrType) {
            0x01 -> repeat(4)  { inp.read() }
            0x03 -> repeat(inp.read()) { inp.read() }
            0x04 -> repeat(16) { inp.read() }
        }
        inp.readShort()

        socket.soTimeout = 0
        sendLog("[CONN] SOCKS5 estabelecido")
        return socket
    }

    // 7. SOCKS4
    private fun connectSocks4(socket: Socket, config: VpnConfig): Socket {
        sendLog("[CONN] SOCKS4 -> ${config.host}:${config.port}")
        socket.connect(InetSocketAddress(config.host, config.port), config.timeout * 1000)

        val out = DataOutputStream(socket.getOutputStream())
        val inp = DataInputStream(socket.getInputStream())
        val targetIp = InetAddress.getByName(config.host).address

        out.write(byteArrayOf(0x04, 0x01))
        out.writeShort(config.port)
        out.write(targetIp)
        out.write(0x00)
        out.flush()

        inp.read()
        val rep = inp.read()
        repeat(6) { inp.read() }
        if (rep != 0x5A) throw IOException("SOCKS4 rejeitado: $rep")

        sendLog("[CONN] SOCKS4 estabelecido")
        return socket
    }

    // ── INTERFACE VPN ───────────────────────────────

    private fun buildVpnInterface(config: VpnConfig): ParcelFileDescriptor {
        sendLog("[VPN] A configurar interface...")
        val dns = config.remoteDns.ifEmpty { "1.1.1.1" }
        return Builder()
            .setSession("Lambula VPN")
            .addAddress("10.8.0.1", 24)
            .addRoute("0.0.0.0", 0)
            .addDnsServer(dns)
            .addDnsServer("8.8.8.8")
            .setMtu(1500)
            .establish()
            ?: throw IOException("Falha ao criar interface VPN")
    }

    // ── PROXY SOCKS5 LOCAL + FORWARDING ─────────────
    //
    // Arquitectura correcta:
    // Apps Android -> tun0 (VPN) -> proxy SOCKS5 local (127.0.0.1:socksPort)
    //                                      -> socket tunel -> servidor remoto
    //
    // O VpnService captura todo o trafico IP.
    // Reencaminhamos para um proxy SOCKS5 local que usa o socket do tunel.

    private fun startLocalProxy(
        vpnFd: ParcelFileDescriptor,
        tunnelSocket: Socket,
        config: VpnConfig
    ) {
        val socksPort = config.socksPort.takeIf { it in 1024..65535 } ?: 1080

        sendLog("[PROXY] A iniciar proxy SOCKS5 local na porta $socksPort")

        // Servidor SOCKS5 local — aceita ligacoes das apps
        val server = ServerSocket(socksPort, 50, InetAddress.getByName("127.0.0.1"))
        socksServer = server

        var bytesSent     = 0L
        var bytesReceived = 0L

        // Thread do servidor proxy
        val proxyThread = thread {
            try {
                while (running) {
                    val client = try { server.accept() } catch (e: Exception) { break }
                    thread { handleSocksClient(client, tunnelSocket, config) }
                }
            } catch (_: Exception) {}
        }

        // Keepalive + relatorio de trafico
        val keepaliveThread = thread {
            try {
                while (running) {
                    Thread.sleep(config.keepalive * 1000L)
                    sendEvent("onTraffic", mapOf("sent" to bytesSent, "received" to bytesReceived))
                }
            } catch (_: InterruptedException) {}
        }

        // Forwarding principal: tun0 -> tunel remoto
        val tunIn  = FileInputStream(vpnFd.fileDescriptor)
        val tunOut = FileOutputStream(vpnFd.fileDescriptor)
        val remoteOut = tunnelSocket.getOutputStream()
        val remoteIn  = tunnelSocket.getInputStream()

        // tun0 -> remoto
        val toRemote = thread {
            try {
                val buf = ByteArray(4096)
                while (running) {
                    val n = tunIn.read(buf)
                    if (n > 0) {
                        remoteOut.write(buf, 0, n)
                        remoteOut.flush()
                        bytesSent += n
                    }
                }
            } catch (e: Exception) {
                if (running) sendLog("[FWD] Upstream encerrado: ${e.message}")
            }
        }

        // remoto -> tun0
        val toTun = thread {
            try {
                val buf = ByteArray(4096)
                while (running) {
                    val n = remoteIn.read(buf)
                    if (n < 0) break
                    if (n > 0) {
                        tunOut.write(buf, 0, n)
                        bytesReceived += n
                    }
                }
            } catch (e: Exception) {
                if (running) sendLog("[FWD] Downstream encerrado: ${e.message}")
            }
        }

        toRemote.join()
        toTun.join()
        keepaliveThread.interrupt()
        proxyThread.interrupt()

        if (running) {
            sendLog("[VPN] Conexao perdida")
            sendEvent("onDisconnected", null)
            cleanup()
        }
    }

    // ── HANDLER SOCKS5 LOCAL ────────────────────────

    private fun handleSocksClient(client: Socket, tunnel: Socket, config: VpnConfig) {
        try {
            client.soTimeout = config.timeout * 1000
            val inp = DataInputStream(client.getInputStream())
            val out = DataOutputStream(client.getOutputStream())

            // Handshake SOCKS5
            val ver = inp.read()
            if (ver != 0x05) { client.close(); return }
            val nMethods = inp.read()
            repeat(nMethods) { inp.read() }
            out.write(byteArrayOf(0x05, 0x00)) // sem auth
            out.flush()

            // Pedido
            inp.read() // VER
            val cmd  = inp.read()
            inp.read() // RSV
            val atyp = inp.read()

            val targetHost = when (atyp) {
                0x01 -> {
                    val ip = ByteArray(4).also { inp.readFully(it) }
                    InetAddress.getByAddress(ip).hostAddress
                }
                0x03 -> {
                    val len = inp.read()
                    String(ByteArray(len).also { inp.readFully(it) })
                }
                0x04 -> {
                    val ip = ByteArray(16).also { inp.readFully(it) }
                    InetAddress.getByAddress(ip).hostAddress
                }
                else -> { client.close(); return }
            }
            val targetPort = inp.readUnsignedShort()

            if (cmd != 0x01) {
                out.write(byteArrayOf(0x05, 0x07, 0x00, 0x01, 0,0,0,0, 0,0))
                client.close(); return
            }

            // Resposta de sucesso
            out.write(byteArrayOf(0x05, 0x00, 0x00, 0x01, 0,0,0,0, 0,0))
            out.flush()

            sendLog("[PROXY] $targetHost:$targetPort")

            // Relay bidirecional entre cliente local e socket remoto
            client.soTimeout = 0
            val tunnelOut = tunnel.getOutputStream()
            val tunnelIn  = tunnel.getInputStream()
            val clientIn  = client.getInputStream()
            val clientOut = client.getOutputStream()

            val t1 = thread {
                try {
                    val buf = ByteArray(4096)
                    while (true) {
                        val n = clientIn.read(buf)
                        if (n < 0) break
                        tunnelOut.write(buf, 0, n)
                        tunnelOut.flush()
                    }
                } catch (_: Exception) {}
            }

            val t2 = thread {
                try {
                    val buf = ByteArray(4096)
                    while (true) {
                        val n = tunnelIn.read(buf)
                        if (n < 0) break
                        clientOut.write(buf, 0, n)
                        clientOut.flush()
                    }
                } catch (_: Exception) {}
            }

            t1.join(); t2.join()

        } catch (_: Exception) {
        } finally {
            try { client.close() } catch (_: Exception) {}
        }
    }

    // ── DISCONNECT ──────────────────────────────────

    private fun disconnect() {
        sendLog("[VPN] A desligar...")
        running = false
        cleanup()
        sendEvent("onDisconnected", null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun cleanup() {
        running = false
        try { socksServer?.close()  } catch (_: Exception) {}
        try { proxySocket?.close()  } catch (_: Exception) {}
        try { vpnInterface?.close() } catch (_: Exception) {}
        socksServer  = null
        proxySocket  = null
        vpnInterface = null
    }

    // ── NOTIFICACAO ─────────────────────────────────

    private fun startForegroundNotification() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID, "Lambula VPN", NotificationManager.IMPORTANCE_LOW)
        manager.createNotificationChannel(channel)

        val pending = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE)

        startForeground(1,
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Lambula VPN")
                .setContentText("VPN activa — LuVita")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(pending)
                .setOngoing(true)
                .build())
    }

    // ── EVENTOS ─────────────────────────────────────

    private fun sendEvent(method: String, args: Any?) = eventCallback?.invoke(method, args)
    private fun sendLog(msg: String) { Log.d(TAG, msg); eventCallback?.invoke("onLog", msg) }
}