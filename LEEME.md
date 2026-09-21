# Impresora térmica en iPhone — análisis y puente nativo

Este archivo acompaña a `index.html`. No hace falta para que el POS funcione:
la app ya trae todo dentro de **Mi cuenta → Impresión de tickets** y, mientras
no exista este puente, imprime por el diálogo del sistema como siempre.

---

## 1. Qué está pasando con tu OFICHIDO de 58 mm

En el iPhone aparece como **"Bluetooth Printer"** y Ajustes → Bluetooth la marca
como incompatible. Eso no es un fallo del rollo ni del POS: es el
comportamiento normal de iOS con este tipo de impresora.

Las térmicas económicas de 58 mm casi siempre traen un módulo Bluetooth que
expone **Bluetooth Classic con perfil SPP** (*Serial Port Profile*), es decir un
puerto serie por Bluetooth por el que se mandan bytes ESC/POS en crudo.

- **Android y Windows** dejan abrir SPP a cualquier app. Por eso la misma
  impresora sí enlaza ahí sin problema.
- **iOS no.** Apple solo permite Bluetooth Classic a accesorios certificados
  **MFi**, a través del framework `ExternalAccessory` y declarando el protocolo
  del fabricante en el `Info.plist`. Una impresora genérica no está en ese
  programa, así que el iPhone la ve anunciarse, intenta enlazar y la rechaza.
  Ese es exactamente el mensaje que estás viendo.
- Además, **Safari no incluye la API Web Bluetooth**, así que ni siquiera para
  los modelos que sí hablan BLE una página web puede conectarse por su cuenta
  en iPhone.

Resultado: **una PWA en iPhone no puede hablar con esa impresora.** Punto. No
es cuestión de código; es la plataforma. Por eso el POS **no** te va a poner
"Conectada" en iOS: te dice la verdad y te deja imprimir por el diálogo del
sistema.

### Antes de nada: averigua si tu modelo también habla BLE

Muchas OFICHIDO y similares son **dual**: Classic SPP + BLE. Si tiene BLE, sí
hay salida real.

1. Instala **nRF Connect** o **LightBlue** en el iPhone (son gratuitas).
2. Enciende la impresora y busca.
3. Si aparece ahí con servicios tipo `18F0`, `FFE0`, `FF00`, `FEE7`, `AE30` o
   `49535343-…`, **habla BLE**. Apunta el nombre exacto.
4. Si no aparece en ninguna de esas apps, es **solo Classic SPP** y en iPhone no
   hay forma de conectarla desde la app: pasa al plan Wi-Fi o USB.

---

## 2. Caminos reales, de menos a más trabajo

| Camino | Funciona si… | Qué necesitas |
|---|---|---|
| **Diálogo del sistema** (ya funciona hoy) | siempre | nada; el ticket sale con el tamaño de papel configurado |
| **Navegador Bluefy / extensión WebBLE** | la impresora tiene **BLE** | abrir el mismo `index.html` en Bluefy; la pantalla conecta sola, sin tocar código |
| **Android o PC con Chrome** | siempre | Web Bluetooth y WebUSB sí existen ahí; la pantalla ya los usa |
| **Wi-Fi puerto 9100** | la impresora tiene Wi-Fi/Ethernet, o pones un agente | ver punto 4 |
| **App nativa con este puente** | la impresora tiene **BLE** (o es MFi) | Capacitor + los archivos de esta carpeta |

---

## 3. Montar el puente nativo (Capacitor)

```bash
npm init -y
npm i @capacitor/core @capacitor/cli @capacitor/ios
npx cap init Mesa com.tunegocio.mesa --web-dir=www

mkdir -p www && cp ../index.html www/index.html

npx cap add ios
npx cap sync ios
npx cap open ios
```

En Xcode, arrastra a `App/App/`:

- `MesaPrinter.swift`
- `MesaPrinter.m` (cuando pregunte por el *bridging header*, di que sí)

Y en `App/App/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Mesa usa Bluetooth para imprimir tus tickets en la impresora térmica.</string>

<key>NSLocalNetworkUsageDescription</key>
<string>Mesa usa la red local para imprimir en impresoras Wi-Fi.</string>
```

Para impresoras Wi-Fi, además:

```xml
<key>NSBonjourServices</key>
<array><string>_pdl-datastream._tcp</string></array>
```

Si tu impresora **sí es MFi**, cambia `CoreBluetooth` por `ExternalAccessory`
en `MesaPrinter.swift` y añade:

```xml
<key>UISupportedExternalAccessoryProtocols</key>
<array><string>com.elfabricante.protocolo</string></array>
```

(el identificador te lo da el fabricante; sin él, no hay nada que hacer).

### El contrato ya está escrito en el HTML

`index.html` busca el puente en `printerNative()`:

```js
window.Capacitor.Plugins.MesaPrinter   // o  window.MesaPrinter
```

y llama a estos métodos, que son los que implementa `MesaPrinter.swift`:

| Método | Entra | Sale |
|---|---|---|
| `scan({type})` | `bt` / `wifi` / `usb` | `{ devices: [{id, name}] }` |
| `connect({id, type, host, port})` | | `{ connected: Bool }` |
| `disconnect()` | | `{ ok: true }` |
| `write({data})` | ESC/POS en **base64** | `{ ok: true }` |
| `netProbe({host, port})` | | `{ ok: Bool }` |
| `netPrint({host, port, data})` | | `{ ok: true }` |

En cuanto el plugin existe, la pantalla de impresión lo detecta sola, muestra
*"Puente nativo activo"* y deja de usar Web Bluetooth. **No hay que cambiar
nada del HTML.**

---

## 4. Agente Wi-Fi (para usar la impresora desde el navegador)

Un navegador no puede abrir un socket TCP al puerto 9100. Si no quieres app
nativa, pon este agente en cualquier PC, Mac o Raspberry de la misma red, con
la impresora enchufada por USB o en red:

```js
// agente.js  ->  node agente.js
const http = require('http');
const net  = require('net');

const IMPRESORA = { host: '192.168.1.50', port: 9100 }; // o una impresora USB compartida

http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin',  '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  if (req.method === 'OPTIONS') return res.end();
  if (req.url === '/status')    return res.end('ok');

  const trozos = [];
  req.on('data', d => trozos.push(d));
  req.on('end', () => {
    const s = net.createConnection(IMPRESORA, () => s.end(Buffer.concat(trozos)));
    s.on('error', () => {});
    res.end('ok');
  });
}).listen(9100, () => console.log('Agente listo en el puerto 9100'));
```

Luego, en **Impresión de tickets → Wi-Fi**, escribe la IP del equipo donde corre
el agente y el puerto `9100`.

> Si el POS lo sirves por **https**, el navegador bloqueará las llamadas a
> `http://` (contenido mixto). En ese caso sirve el POS por http en la red
> local, o ponle un certificado al agente.

---

## 5. Qué manda el POS por el cable

El ticket sale en **ESC/POS**, con el mismo contenido y el mismo orden que el
ticket de siempre:

`ESC @` reinicio · `ESC t` tabla de caracteres (CP437 / CP850) · `ESC a`
alineación · `ESC E` negritas · `GS !` doble alto y ancho para el nombre del
negocio y el TOTAL · nombre, subtítulo, dirección y teléfono · pedido, fecha y
hora, servicio, mesa y quién atendió · productos con cantidad y precio ·
subtotal · IVA 16% · TOTAL · método de pago, recibido y cambio · VENTA
CANCELADA si aplica · mensaje final · `ESC d` papel extra · `GS V` corte, si la
impresora lo trae. El logo, si está activado, va como mapa de bits `GS v 0`.

El ancho de columnas sale del papel que ya elegiste: **58 mm → 32 columnas**,
**80 mm → 48 columnas**.
