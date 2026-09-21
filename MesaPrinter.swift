import Foundation
import Capacitor
import CoreBluetooth
import Network

/*
 MesaPrinter — puente nativo de iOS para la impresora térmica.

 Implementa EXACTAMENTE el contrato que ya usa index.html:

   window.MesaPrinter.scan({ type })              -> { devices: [{ id, name }] }
   window.MesaPrinter.connect({ id, type, host, port }) -> { connected: Bool }
   window.MesaPrinter.disconnect()                -> { ok: true }
   window.MesaPrinter.write({ data })             -> { ok: true }     (data = base64)
   window.MesaPrinter.netProbe({ host, port })    -> { ok: Bool }
   window.MesaPrinter.netPrint({ host, port, data }) -> { ok: true }

 En cuanto este plugin existe, la pantalla
 "Mi cuenta -> Impresión de tickets" lo detecta sola y deja de usar
 Web Bluetooth. No hay que tocar una línea del HTML.

 LÍMITE REAL DE iOS, sin rodeos:
   · CoreBluetooth (lo que usa este archivo) habla SOLO con BLE / GATT.
   · Si la impresora es Bluetooth Classic SPP y NO es MFi, ni este plugin
     ni ningún otro la pueden abrir: Apple no expone SPP a apps normales.
     Para esas, las salidas reales son Wi-Fi (netPrint, puerto 9100),
     USB-host en otro equipo, o cambiar a un modelo BLE o MFi.
   · Si el modelo SÍ es MFi, se usa ExternalAccessory en vez de
     CoreBluetooth y hay que declarar su protocolo en UISupportedExternalAccessoryProtocols.
*/

@objc(MesaPrinter)
public class MesaPrinter: CAPPlugin, CBCentralManagerDelegate, CBPeripheralDelegate {

    // UUID de servicio que anuncian las térmicas ESC/POS BLE más comunes.
    private let servicios: [CBUUID] = [
        CBUUID(string: "18F0"),
        CBUUID(string: "FF00"),
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFB0"),
        CBUUID(string: "FEE7"),
        CBUUID(string: "AE30"),
        CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"),
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2")
    ]

    private var central: CBCentralManager!
    private var encontrados: [String: CBPeripheral] = [:]
    private var activa: CBPeripheral?
    private var canal: CBCharacteristic?          // característica de escritura
    private var sinRespuesta = false

    private var llamadaScan: CAPPluginCall?
    private var llamadaConnect: CAPPluginCall?

    override public func load() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Buscar

    @objc func scan(_ call: CAPPluginCall) {
        guard central.state == .poweredOn else {
            call.reject("Enciende el Bluetooth del iPhone")
            return
        }
        encontrados.removeAll()
        llamadaScan = call
        call.keepAlive(true)

        // nil = ver todo lo que anuncie: muchas térmicas no publican su servicio.
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self else { return }
            self.central.stopScan()
            let lista = self.encontrados.map { (id, p) -> [String: Any] in
                ["id": id, "name": p.name ?? "Impresora Bluetooth"]
            }
            self.llamadaScan?.resolve(["devices": lista])
            self.llamadaScan?.keepAlive(false)
            self.llamadaScan = nil
        }
    }

    public func centralManager(_ c: CBCentralManager,
                               didDiscover p: CBPeripheral,
                               advertisementData d: [String: Any],
                               rssi RSSI: NSNumber) {
        // Sin nombre casi siempre es ruido (balizas, wearables ajenos).
        guard let nombre = p.name, !nombre.isEmpty else { return }
        encontrados[p.identifier.uuidString] = p
    }

    // MARK: - Conectar

    @objc func connect(_ call: CAPPluginCall) {
        let tipo = call.getString("type") ?? "bt"
        if tipo == "wifi" {
            let host = call.getString("host") ?? ""
            let port = call.getInt("port") ?? 9100
            probar(host: host, port: port) { ok in call.resolve(["connected": ok]) }
            return
        }
        guard let id = call.getString("id"), let uuid = UUID(uuidString: id) else {
            call.reject("Falta el identificador de la impresora")
            return
        }
        let candidato = encontrados[id]
            ?? central.retrievePeripherals(withIdentifiers: [uuid]).first
        guard let p = candidato else {
            call.reject("Esa impresora ya no está enlazada. Búscala de nuevo.")
            return
        }
        llamadaConnect = call
        call.keepAlive(true)
        activa = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices(nil)
    }

    public func centralManager(_ c: CBCentralManager,
                               didFailToConnect p: CBPeripheral, error: Error?) {
        terminarConnect(ok: false, motivo: error?.localizedDescription ?? "No se pudo conectar")
    }

    public func centralManager(_ c: CBCentralManager,
                               didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        canal = nil
        activa = nil
        // El JS ya vuelve a poner "Desconectada" cuando falla un envío,
        // y además se avisa por si la pantalla está abierta.
        notifyListeners("printerDisconnected", data: [:])
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let servs = p.services, !servs.isEmpty else {
            terminarConnect(ok: false, motivo: "La impresora no expone servicios BLE")
            return
        }
        servs.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(_ p: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard canal == nil, let chars = service.characteristics else { return }
        for c in chars {
            if c.properties.contains(.writeWithoutResponse) {
                canal = c; sinRespuesta = true; break
            }
            if c.properties.contains(.write) {
                canal = c; sinRespuesta = false; break
            }
        }
        if canal != nil { terminarConnect(ok: true, motivo: nil) }
    }

    private func terminarConnect(ok: Bool, motivo: String?) {
        guard let call = llamadaConnect else { return }
        llamadaConnect = nil
        call.keepAlive(false)
        if ok { call.resolve(["connected": true]) }
        else {
            if let p = activa { central.cancelPeripheralConnection(p) }
            activa = nil
            call.reject(motivo ?? "No se pudo conectar")
        }
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        if let p = activa { central.cancelPeripheralConnection(p) }
        activa = nil
        canal = nil
        call.resolve(["ok": true])
    }

    // MARK: - Escribir ESC/POS

    @objc func write(_ call: CAPPluginCall) {
        guard let b64 = call.getString("data"),
              let datos = Data(base64Encoded: b64) else {
            call.reject("Datos inválidos")
            return
        }
        guard let p = activa, let c = canal else {
            call.reject("No hay ninguna impresora conectada")
            return
        }
        // Las térmicas BLE baratas se atragantan con paquetes grandes.
        let tope = min(p.maximumWriteValueLength(for: sinRespuesta ? .withoutResponse : .withResponse), 180)
        let paso = max(20, tope)
        var i = 0
        while i < datos.count {
            let fin = min(i + paso, datos.count)
            p.writeValue(datos.subdata(in: i..<fin),
                         for: c,
                         type: sinRespuesta ? .withoutResponse : .withResponse)
            i = fin
            if sinRespuesta { Thread.sleep(forTimeInterval: 0.012) }
        }
        call.resolve(["ok": true])
    }

    // MARK: - Wi-Fi (socket TCP 9100, lo que el navegador NO puede hacer)

    @objc func netProbe(_ call: CAPPluginCall) {
        let host = call.getString("host") ?? ""
        let port = call.getInt("port") ?? 9100
        probar(host: host, port: port) { ok in call.resolve(["ok": ok]) }
    }

    @objc func netPrint(_ call: CAPPluginCall) {
        let host = call.getString("host") ?? ""
        let port = call.getInt("port") ?? 9100
        guard let b64 = call.getString("data"),
              let datos = Data(base64Encoded: b64) else {
            call.reject("Datos inválidos")
            return
        }
        enviar(host: host, port: port, datos: datos) { ok, motivo in
            if ok { call.resolve(["ok": true]) } else { call.reject(motivo ?? "No se pudo enviar") }
        }
    }

    private func conexion(host: String, port: Int) -> NWConnection? {
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
    }

    private func probar(host: String, port: Int, listo: @escaping (Bool) -> Void) {
        guard let conn = conexion(host: host, port: port) else { listo(false); return }
        var contestado = false
        conn.stateUpdateHandler = { estado in
            switch estado {
            case .ready:
                if !contestado { contestado = true; conn.cancel(); listo(true) }
            case .failed, .cancelled:
                if !contestado { contestado = true; listo(false) }
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if !contestado { contestado = true; conn.cancel(); listo(false) }
        }
    }

    private func enviar(host: String, port: Int, datos: Data,
                        listo: @escaping (Bool, String?) -> Void) {
        guard let conn = conexion(host: host, port: port) else {
            listo(false, "Dirección inválida"); return
        }
        conn.stateUpdateHandler = { estado in
            switch estado {
            case .ready:
                conn.send(content: datos, completion: .contentProcessed { err in
                    conn.cancel()
                    if let e = err { listo(false, e.localizedDescription) } else { listo(true, nil) }
                })
            case .failed(let e):
                conn.cancel(); listo(false, e.localizedDescription)
            default: break
            }
        }
        conn.start(queue: .global())
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ c: CBCentralManager) { }
}
