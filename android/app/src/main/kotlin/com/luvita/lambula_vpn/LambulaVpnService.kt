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

    private var vpnInterface: ParcelFileDescriptor? = null
    private var running = false
    private var tunnelThread: Thread? = null

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
                sendLog("[VPN] A iniciar — metodo: ${config.injectMethod}")
                sendLog("[VPN] Host: ${config.host}:${config.port}")

                // 1. Criar interface VPN primeiro
                val vpnFd = buildVpnInterface(config)
                vpnInterface = vpnFd
                running = true

                sendLog("[VPN] Interface criada")

                // 2. Notificar Flutter que esta conectado
                // O Flutter usa dartssh2 para fazer o tunel SSH real
                sendEvent("onConnected", mapOf(
                    "ip" to config.host,
                    "location" to config.host,
                    "socksPort" to config.socksPort,
                ))

                sendLog("[VPN] Pronto — a aguardar tunel SSH do Flutter")

                // 3. Manter interface VPN activa
                keepAlive(vpnFd, config)

            } catch (e: Exception) {
                Log.e(TAG, "Erro", e)
                sendLog("[ERRO] ${e.message}")
                sendEvent("onError", e.message)
                cleanup()
            }
        }
    }

    // ── KEEP ALIVE DA INTERFACE VPN ─────────────────

    private fun keepAlive(vpnFd: ParcelFileDescriptor, config: VpnConfig) {
        var bytesSent     = 0L
        var bytesReceived = 0L

        // Thread que le pacotes da interface VPN
        // (necessario para manter a interface activa)
        val readThread = thread {
            try {
                val buf = ByteArray(4096)
                val fis = FileInputStream(vpnFd.fileDescriptor)
                while (running) {
                    val n = fis.read(buf)
                    if (n > 0) bytesSent += n
                }
            } catch (_: Exception) {}
        }

        // Relatorio de trafico periodico
        val trafficThread = thread {
            try {
                while (running) {
                    Thread.sleep(config.keepalive * 1000L)
                    sendEvent("onTraffic", mapOf(
                        "sent"     to bytesSent,
                        "received" to bytesReceived,
                    ))
                }
            } catch (_: InterruptedException) {}
        }

        readThread.join()
        trafficThread.interrupt()

        if (running) {
            sendLog("[VPN] Interface encerrada")
            sendEvent("onDisconnected", null)
            cleanup()
        }
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
        try { vpnInterface?.close() } catch (_: Exception) {}
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
                .setContentText("VPN activa - LuVita")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(pending)
                .setOngoing(true)
                .build())
    }

    // ── EVENTOS ─────────────────────────────────────

    private fun sendEvent(method: String, args: Any?) = eventCallback?.invoke(method, args)
    private fun sendLog(msg: String) { Log.d(TAG, msg); eventCallback?.invoke("onLog", msg) }
}