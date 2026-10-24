<div align="center">

<h1>VRChat Network Optimizer</h1>

<p>Herramienta para Windows que mejora la calidad de red de VRChat — optimización de hosts y núcleos opcionales winws (elusión DPI) y mihomo (Clash.Meta).</p>

<a href="https://github.com/AndySmithmao/netkit-l9x2/releases"><img alt="Release" src="https://img.shields.io/github/v/release/AndySmithmao/netkit-l9x2?style=flat-square&color=1E9BFA"></a>
<a href="https://github.com/AndySmithmao/netkit-l9x2/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/AndySmithmao/netkit-l9x2/total?style=flat-square&color=1E9BFA"></a>
<img alt="Platform" src="https://img.shields.io/badge/platform-Windows%2010%2F11%20x64-1E9BFA?style=flat-square">
<img alt="License" src="https://img.shields.io/badge/license-MIT-green?style=flat-square">

</div>

<div align="center">

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md) · [Español](README.es.md)

</div>
Herramienta de escritorio para Windows que mejora la calidad de red de VRChat. Incluye dos núcleos:
winws (elusión de DPI de zapret) y mihomo (Clash.Meta), además de una vía de optimización de hosts que no
requiere proxy. Está escrita en WPF sobre .NET 10 y necesita permisos de administrador para ejecutarse.

Versión actual 0.0.4-beta; tanto las funciones como la interfaz pueden cambiar.

## Qué problema resuelve

La calidad de la conexión de VRChat depende de la ruta hasta los servidores de Photon. En algunas redes
aparece una o varias de estas situaciones:

- el DNS devuelve IP poco eficientes, con latencia alta o pérdida de paquetes;
- el tránsito internacional da un rodeo grande y un solo salto añade más de 100 ms;
- parte de la ruta sufre interferencia DPI, que se manifiesta en handshakes fallidos o reconexiones frecuentes.

Para los dos primeros casos la herramienta escanea rangos de Cloudflare y CloudFront, mide latencia y velocidad
de descarga, y escribe las IP con mejor resultado en el archivo hosts. Para el tercero, y cuando el tráfico debe
salir por otra región, un núcleo proxy enruta según reglas. Ambos enfoques funcionan por separado o combinados.

## Descarga

Los nombres de los archivos publicados son fijos, así que estos enlaces siempre apuntan a la última compilación:

- Instalador: `https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe`
- Portátil: `https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Portable.exe`

En algunas redes el acceso a github.com es inestable. Se puede anteponer un prefijo de espejo:

```
https://ghproxy.net/https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe
```

El actualizador incluido usa los mismos espejos, probando ghproxy.net, gh-proxy.com y ghfast.top en ese orden.

El instalador está firmado con un certificado propio, así que SmartScreen puede advertir de un editor
desconocido; elige "Ejecutar de todos modos". La ruta predeterminada es `C:\Program Files\VRChat优选工具`.
La aplicación solicita permisos de administrador al iniciarse, necesarios para escribir el archivo hosts,
cargar el controlador WinDivert y habilitar TUN.

## Tres formas de usarla

**Solo optimización de hosts.** Abre "Un clic" y pulsa iniciar. La herramienta comprueba el entorno,
escanea los rangos, mide latencia y velocidad de descarga, y muestra una lista de candidatos; elige una IP
y se escribirá y verificará. Indicado si no quieres usar proxy.

**Con nodos proxy.** Pega una suscripción de Clash en la página Suscripción, elige un nodo en Nodos y luego
inicia mihomo en la página Núcleo. Si quieres todo el tráfico por proxy, activa TUN y reinicia mihomo.
Antes de elegir nodo puedes compararlos en la página Ping.

**Elusión de DPI con winws.** Inicia winws en la página Núcleo; usa el perfil desync incluido.
Si una versión anterior registró el servicio `VRChatBypass`, ejecuta primero "Migrar servicio heredado",
de lo contrario dos filtros competirán por el mismo handle.

## Páginas

La navegación izquierda está agrupada por uso. "Un clic" es el flujo automático descrito arriba.
"Operación" contiene instalación, desinstalación y diagnóstico. "Flujo de trabajo" ofrece los cuatro pasos
por separado: escaneo completo, medición de latencia, medición de descarga y selección de la lista.

"Núcleo y proxy" tiene cuatro páginas:

- Núcleo: iniciar, detener y reiniciar winws y mihomo, versión actual, diagnóstico y migración del servicio heredado
- Suscripción: importar y actualizar la URL de suscripción; al guardar, mihomo se inicia automáticamente
- Nodos: lista de nodos en tarjetas, cambio con un clic, medición de latencia por lotes, interruptores de TUN y modo proxy
- Ping: para una IP o nombre de host, hace un handshake TCP + TLS a través de cada nodo y ordena por latencia ascendente

Ajustes incluye tema, escala de interfaz y el acceso a la actualización de la aplicación.

## Por qué Ping no usa ICMP

mihomo trata ICMP siempre como DIRECT, así que el núcleo no puede entregar ICMP al proxy.
Midiendo la misma IP a través de nodos de EE. UU., Japón y Hong Kong el resultado ronda 172 ms en todos los casos,
que es la ruta directa local, de modo que el número no aporta información. Por eso el "Ping de nodo" aquí es
un handshake TCP, concretamente un handshake TLS completo contra el puerto 443 para obtener el tiempo real de ida y vuelta.
Con una IP de Google: Hong Kong 87 ms, Japón 80 ms, EE. UU. 551 ms, suficiente para distinguir nodos.

Lo contrario también se cumple: si el destino solo responde a ICMP o a un protocolo UDP propietario
(los servidores de juego de Photon funcionan así), no se puede medir la latencia por nodo y solo se observa la ruta directa.

## Cómo se escriben las entradas de hosts

Las IP seleccionadas se escriben en el archivo hosts del sistema entre un par de marcadores,
que la desinstalación usa para limpiar:

```
# ===== VRChat-bypass BEGIN =====
104.18.26.36  example.com
# ===== VRChat-bypass END =====
```

Los candidatos provienen de 5956 rangos /24 de Cloudflare y 16552 rangos /24 de CloudFront,
se filtran con ICMP y TLS, y luego se miden con varias rondas de latencia y una descarga real.

## Por qué los núcleos no son servicios de Windows

Las versiones iniciales registraban winws como servicio de Windows. Tras `sc stop` los objetos de filtro WFP
no se liberaban y el siguiente arranque fallaba con `FWP_E_IN_USE 0x8032000A`, recuperable solo reiniciando.
Ahora el núcleo se ejecuta como proceso hijo gestionado por la aplicación y se limpia por la ruta del ejecutable;
tres ciclos consecutivos de parada y arranque terminan sin errores.

- winws captura y reescribe paquetes con WinDivert usando el perfil desync incluido
- mihomo gestiona los nodos de suscripción y el enrutado por reglas; el modo TUN necesita permisos de administrador

## Directorios en tiempo de ejecución

```
C:\Program Files\VRChat优选工具\
  tools\                    componentes (winws.exe, WinDivert, cygwin1.dll)
  data\logs\session-*.log   registros de sesión

C:\ProgramData\VrcTool\
  drivers\winws\            se extrae en el primer arranque
  drivers\mihomo\           mihomo, configuración, caché de suscripción, state.json
  logs\drivers.log          salida de ambos núcleos
```

Al cerrar la aplicación se detienen los procesos de los núcleos y no queda nada en segundo plano.

## Actualizaciones

Unos cinco segundos después de iniciar se comprueban las versiones de la aplicación y de ambos núcleos;
si hay una nueva se muestra un diálogo. Rechazar la omite en esta sesión. La página de ajustes permite
comprobarla manualmente.

La actualización de la aplicación descarga el instalador, verifica su SHA256, lo ejecuta y se cierra.
La de un núcleo renombra primero los archivos antiguos a `.bak`, los reemplaza y prueba a arrancar;
si falla, revierte.

Los resultados se guardan en caché seis horas. La API anónima de GitHub permite 60 peticiones por hora
y una comprobación al iniciar consume tres, así que arranques repetidos agotan el límite. La comprobación
manual ignora la caché.

## Compilar desde el código fuente

Requiere el SDK de .NET 10; para generar el instalador también MSBuild de Visual Studio 2022 o 2026.

```
git clone https://github.com/AndySmithmao/netkit-l9x2.git
cd netkit-l9x2

dotnet build src\app\VrcTool.csproj -c Release

powershell -File src\setup\build-installer.ps1
```

El script de compilación ejecuta primero `tools\verify.ps1`, que revisa codificación de archivos
(lo que contenga caracteres no ASCII debe ser UTF-8 con BOM), sintaxis de los scripts, duplicación entre
los dos árboles de scripts, rutas codificadas restantes, lista de recursos incrustados y coherencia de versiones.
Cualquier fallo detiene la compilación.

### mihomo.exe debe aportarse

`src\drivers\mihomo.exe` ocupa unos 61 MB y no está en el repositorio. Antes de compilar, descarga
`mihomo-windows-amd64-vX.Y.Z.zip` desde el upstream, extrae `mihomo.exe` en `src\drivers\` y crea
`mihomo.VERSION.txt` (por ejemplo `Mihomo Meta v1.19.32 windows amd64`), que el actualizador usa para comparar.

winws.exe, cygwin1.dll y los dos archivos de WinDivert sí están incluidos.

### Problemas de compilación habituales

`error CS1566: no se pudo leer el recurso WinDivert64.sys` indica que un winws en ejecución tiene el archivo bloqueado.
Detén winws o borra `obj` y `bin` y vuelve a compilar.

Si `verify.ps1` informa de falta de BOM, ejecuta `tools\fix-bom.ps1` una vez.

Un instalador de solo dos o tres megabytes significa que el empaquetado de mica no incluyó la carga útil.
La causa habitual es un número de versión con sufijo (`0.0.1-beta`), ya que makemica solo acepta versiones numéricas.
El script de compilación elimina el sufijo automáticamente, pero conviene tenerlo en cuenta al invocarlo a mano.

## Limitaciones conocidas

ICMP no se puede proxificar, por lo que la medición por nodo depende del handshake TCP y los destinos que solo
responden a ICMP no se pueden medir.

La API anónima de GitHub permite 60 peticiones por hora; arranques repetidos pueden alcanzar el límite,
mitigado con la caché de seis horas.

mihomo ocupa los puertos 7891 y 9097. Si ya hay otra instancia en ejecución hay conflicto de puertos y el síntoma
es una suscripción que se importa correctamente pero deja la lista de nodos vacía.

Solo Windows x64, por depender de WinDivert y WPF.

## Licencia y componentes de terceros

El código del proyecto es MIT, ver `LICENSE`. Los binarios de los núcleos incluidos no son MIT y siguen las
licencias de sus proyectos originales, detalladas en `NOTICE.md`. WinDivert tiene doble licencia LGPL-3.0 o GPL-2.0,
cygwin1.dll es LGPL-3.0 con excepción de enlazado; ambos se distribuyen como archivos separados, sin enlazado
estático ni modificaciones.

Dependencias principales:

- mihomo (Clash.Meta) — https://github.com/MetaCubeX/mihomo
- zapret / zapret-win-bundle — https://github.com/bol-van/zapret
- WinDivert — https://github.com/basil00/WinDivert
- Cygwin — https://cygwin.com/
- .NET y WPF — https://github.com/dotnet/wpf
- WPF-UI — https://github.com/lepoco/wpfui

## Aviso legal

Este proyecto es una herramienta genérica de diagnóstico de red y control de rutas. No está dirigido a ningún
país, región u operador de red en particular.

El software modifica el archivo hosts del sistema, carga un controlador de núcleo y puede activar TUN,
redirigiendo el tráfico de todo el equipo. Evalúa los riesgos antes de ejecutarlo.

Es responsabilidad del usuario cumplir la legislación aplicable en su jurisdicción, así como los términos de
servicio de su operador de red, VPN o proveedor de proxy. No utilices esta herramienta para eludir normas
que estás obligado a cumplir.

Los autores ofrecen el software "tal cual", sin garantía de ningún tipo, y no asumen responsabilidad por daños,
interrupciones del servicio, sanciones de cuenta u otras pérdidas derivadas de su uso.

