# CLAUDE.md — CullApp

## Proyecto
**CullApp** — desinstalador estilo AppCleaner para macOS, compatible Mac App Store.

## Nombre y Bundle ID
- **App:** CullApp
- **Helper:** CullAppHelper
- **Bundle ID app:** com.cullapp.CullApp
- **Bundle ID helper:** com.cullapp.CullApp.PrivilegedHelper
- **XPC service:** com.cullapp.CullAppHelper

## Objetivo
- Publicar en la **Mac App Store**
- Drag & drop .app sobre ventana → detecta y elimina residuos
- Privileged helper via **SMJobBless** para archivos root (/Library)
- Smart detection por bundle identifier

## Restricciones App Store
- ❌ Finder Sync Extension → Apple lo rechaza
- ❌ NSAppleScript admin → prohibido
- ✅ SMJobBless helper → sí permitido
- ✅ Drag & drop sobre ventana
- ✅ NSWorkspace.shared.moveToTrash() para .app
- ✅ Acceso ~/Library/* (sandbox) para leftovers

## Stack
- SwiftUI + MVVM con @Observable
- Xcode 26 / macOS 14+
- OpenCode como agente en Mac mini
- xcodegen para generar .xcodeproj

## Ubicación
- Mac mini: `/Users/clot/Projects/CullApp/`
- SSH: `ssh -i ~/.ssh/id_rsa_remote clot@192.168.1.201`
- GitHub: https://github.com/polidisio/CullApp

## Arquitectura

```
CullApp.app (sandbox)
  ├── SwiftUI drop zone
  ├── FileScanner → detecta residuos por bundle ID
  └── XPC Client → com.cullapp.CullAppHelper
                        └── PrivilegedHelper (root)
                            └── borra archivos root → Trash
```

## Métricas v1
- [ ] App compila y arranca ✅
- [ ] Drop .app → muestra archivos a eliminar
- [ ] Confirmación antes de eliminar
- [ ] Archivos van a Trash
- [ ] Privileged helper instala via SMJobBless
- [ ] Archivos root → helper
- [ ] Submit App Store

## Flujo de trabajo
1. OpenCode spike → arquitectura SMJobBless ✅
2. Spec y proyecto base ✅
3. Código v1 → en desarrollo
4. Review con Jose antes de cada commit
