# Lambula VPN 🐟
**by LuVita · Eng. Anthony**

App VPN leve, glassmórfico, para Android 8+, com notificações push do administrador.

---

## 📁 Estrutura do projecto

```
lambula_vpn/
├── lib/
│   └── main.dart                  ← Todo o app (single-file)
├── android/
│   ├── app/
│   │   ├── build.gradle           ← Config Android (minSdk 26)
│   │   ├── google-services.json   ← ⚠️ Tens de adicionar tu (Firebase)
│   │   └── src/main/
│   │       ├── AndroidManifest.xml
│   │       ├── kotlin/com/luvita/lambula_vpn/
│   │       │   └── MainActivity.kt
│   │       └── res/
│   │           ├── values/styles.xml
│   │           ├── values/colors.xml
│   │           └── xml/network_security_config.xml
│   ├── build.gradle               ← Project-level
│   ├── gradle.properties
│   ├── settings.gradle
│   └── gradle/wrapper/
│       └── gradle-wrapper.properties
└── pubspec.yaml
```

---

## 🚀 Como gerar o APK

### 1. Pré-requisitos
- Flutter SDK ≥ 3.0
- Android SDK (API 26+)
- Java 17+
- Conta Firebase

### 2. Configurar Firebase (OBRIGATÓRIO para notificações)
1. Acede a [console.firebase.google.com](https://console.firebase.google.com)
2. Cria um projecto → Adiciona app Android
3. Package name: `com.luvita.lambula_vpn`
4. Faz download do `google-services.json`
5. Coloca-o em `android/app/google-services.json`

### 3. Instalar dependências
```bash
flutter pub get
```

### 4. Gerar APK
```bash
# APK debug (para testar)
flutter build apk --debug

# APK release universal (para distribuir — funciona em todos Android 8+)
flutter build apk --release

# AAB para Google Play
flutter build appbundle --release
```

O APK estará em: `build/app/outputs/flutter-apk/app-release.apk`

---

## 🔔 Sistema de Notificações Push (Admin → Utilizadores)

### Como funciona
1. O admin acede ao painel Firebase → Cloud Messaging
2. Escreve a mensagem e envia
3. **Todos os utilizadores online recebem a notificação** imediatamente, mesmo com o app em background

### Enviar mensagem pelo Firebase Console
1. Firebase Console → Cloud Messaging → Nova campanha
2. Preenche Título e Mensagem
3. Target: "All users" (ou segmentar por país/versão)
4. Envia

### Enviar mensagem por API (para o teu site)
```bash
curl -X POST https://fcm.googleapis.com/fcm/send \
  -H "Authorization: key=SEU_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "to": "/topics/all",
    "notification": {
      "title": "Lambula VPN",
      "body": "Novos servidores adicionados! Actualiza o app."
    }
  }'
```

Para subscrever todos os utilizadores ao tópico `/topics/all`, adiciona no `main.dart`:
```dart
await FirebaseMessaging.instance.subscribeToTopic('all');
```
(já incluído no código)

---

## 📡 Configuração de Servidores (JSON)

Hospeda um ficheiro `config.json` no GitHub Raw ou qualquer URL pública:

```json
{
  "appName": "Lambula VPN",
  "version": "1.0.0",
  "announcement": "Bem-vindo à Lambula VPN! 🐟",
  "servers": [
    {
      "id": "ao-01",
      "name": "Angola #1",
      "country": "Angola",
      "countryCode": "AO",
      "host": "servidor.exemplo.com",
      "port": 22,
      "username": "vpnuser",
      "password": "senha_segura",
      "protocol": "SSH",
      "payload": "",
      "ping": 45,
      "premium": false
    },
    {
      "id": "pt-01",
      "name": "Portugal #1",
      "country": "Portugal",
      "countryCode": "PT",
      "host": "pt.servidor.exemplo.com",
      "port": 80,
      "username": "vpnuser",
      "password": "senha_segura",
      "protocol": "HTTP",
      "payload": "GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]",
      "ping": 120,
      "premium": false
    }
  ]
}
```

Actualiza `kConfigUrl` no `main.dart` com a tua URL.

---

## ⚙️ GitHub Actions (build automático)

Cria `.github/workflows/build.yml`:

```yaml
name: Build APK
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.22.0'
      - name: Add google-services.json
        run: echo "${{ secrets.GOOGLE_SERVICES_JSON }}" | base64 -d > android/app/google-services.json
      - run: flutter pub get
      - run: flutter build apk --release
      - uses: actions/upload-artifact@v4
        with:
          name: lambula-vpn-release
          path: build/app/outputs/flutter-apk/app-release.apk
```

Adiciona o `google-services.json` em base64 como secret `GOOGLE_SERVICES_JSON` no GitHub.

---

## 📱 Compatibilidade
| Android | Versão | Suporte |
|---------|--------|---------|
| 8.0 Oreo | API 26 | ✅ Mínimo |
| 9.0 Pie | API 28 | ✅ |
| 10 | API 29 | ✅ |
| 11 | API 30 | ✅ |
| 12 | API 31 | ✅ |
| 13 | API 33 | ✅ |
| 14 | API 34 | ✅ Alvo |

---

*Lambula VPN · LuVita Angola · Eng. Anthony · 2024*
