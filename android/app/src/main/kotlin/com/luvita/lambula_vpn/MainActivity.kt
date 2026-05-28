package com.luvita.lambula_vpn

import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL            = "com.luvita.lambula_vpn/vpn"
    private val VPN_PERMISSION_CODE = 100
    private var pendingResult: MethodChannel.Result? = null
    private lateinit var methodChannel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {

                "requestVpnPermission" -> {
                    val intent = VpnService.prepare(this)
                    if (intent != null) {
                        pendingResult = result
                        startActivityForResult(intent, VPN_PERMISSION_CODE)
                    } else {
                        result.success(true)
                    }
                }

                "connect" -> {
                    val args = call.arguments as Map<*, *>
                    val intent = Intent(this, LambulaVpnService::class.java).apply {
                        action = LambulaVpnService.ACTION_CONNECT
                        putExtra("host",         args["host"]         as? String ?: "")
                        putExtra("port",         args["port"]         as? Int    ?: 22)
                        putExtra("username",     args["username"]     as? String ?: "")
                        putExtra("password",     args["password"]     as? String ?: "")
                        putExtra("protocol",     args["protocol"]     as? String ?: "SSH")
                        putExtra("uuid",         args["uuid"]         as? String ?: "")
                        putExtra("sni",          args["sni"]          as? String ?: "")
                        putExtra("remoteDns",    args["remoteDns"]    as? String ?: "1.1.1.1")
                        putExtra("payload",      args["payload"]      as? String ?: "")
                        putExtra("injectMethod", args["injectMethod"] as? String ?: "none")
                        putExtra("proxyUser",    args["proxyUser"]    as? String ?: "")
                        putExtra("proxyPass",    args["proxyPass"]    as? String ?: "")
                        putExtra("socksPort",    args["socksPort"]    as? Int    ?: 1080)
                        putExtra("keepalive",    args["keepalive"]    as? Int    ?: 30)
                        putExtra("timeout",      args["timeout"]      as? Int    ?: 15)
                    }
                    startForegroundService(intent)
                    result.success(true)
                }

                "disconnect" -> {
                    val intent = Intent(this, LambulaVpnService::class.java).apply {
                        action = LambulaVpnService.ACTION_DISCONNECT
                    }
                    startService(intent)
                    result.success(true)
                }

                // ── PROTECT SOCKET ──────────────────────────────────────────
                // O Flutter envia host+port do socket SSH.
                // Delegamos para o LambulaVpnService que tem acesso ao protect().
                // A solução principal é o addDisallowedApplication() no serviço
                // (exclui o próprio app do túnel VPN), mas este método serve
                // como camada extra de protecção para sockets individuais.
                "protectSocket" -> {
                    try {
                        val args = call.arguments as? Map<*, *>
                        if (args != null) {
                            val host = args["host"] as? String ?: ""
                            val port = args["port"] as? Int    ?: 0
                            // Delegar para o serviço activo
                            val protected = LambulaVpnService.instance?.protectSocketByAddress(host, port) ?: false
                            result.success(protected)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        // Não fatal — o addDisallowedApplication() já protege
                        result.success(false)
                    }
                }

                else -> result.notImplemented()
            }
        }

        LambulaVpnService.eventCallback = { method, args ->
            runOnUiThread {
                methodChannel.invokeMethod(method, args)
            }
        }
    }

    override fun onActivityResult(
        requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_CODE) {
            pendingResult?.success(resultCode == RESULT_OK)
            pendingResult = null
        }
    }
}
