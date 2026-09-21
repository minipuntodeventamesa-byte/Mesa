#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

/* Registro del plugin para que Capacitor lo publique en
   window.Capacitor.Plugins.MesaPrinter, que es justo donde
   index.html lo busca en printerNative(). */

CAP_PLUGIN(MesaPrinter, "MesaPrinter",
    CAP_PLUGIN_METHOD(scan,       CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(connect,    CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(disconnect, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(write,      CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(netProbe,   CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(netPrint,   CAPPluginReturnPromise);
)
