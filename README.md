# BrainDrift — Deployment Drift Detection (PowerShell)

Small PowerShell toolkit to detect configuration/deployment drift between:
- A = baseline (last successful deployment)
- B = current server state
- C = incoming package (manifest)

**Files**
- [src/DeploymentDrift.Common.psm1](src/DeploymentDrift.Common.psm1) — shared functions and comparison engine
- [src/DeploymentDrift.Common.psd1](src/DeploymentDrift.Common.psd1) — module manifest
- [scripts/New-DeploymentBaseline.ps1](scripts/New-DeploymentBaseline.ps1) — create baseline JSON from a trusted server
- [scripts/Test-DeploymentDrift.ps1](scripts/Test-DeploymentDrift.ps1) — run pre-deployment drift check and write drift report
- [scripts/Export-DeploymentFileManifest.ps1](scripts/Export-DeploymentFileManifest.ps1) — produce incoming package manifest
- [tests/DeploymentDrift.Tests.ps1](tests/DeploymentDrift.Tests.ps1) — Pester integration tests (runs scripts externally)

Quick start

1. Import the module locally from the repo (preferred via manifest):

```powershell
Import-Module .\src\DeploymentDrift.Common.psd1 -Scope Local -Force
```

2. Create a baseline from a trusted server:

```powershell
.\scripts\New-DeploymentBaseline.ps1 -ApplicationName 'MyApp' -DeploymentId '20260530' \
    -EnvironmentName 'Prod' -ServerName 'web01' -RootPath 'C:\inetpub\wwwroot' \
    -BaselinePath 'C:\deploy\baseline\last-successful-deployment.json' -IncludePatterns '*'
```

3. Export incoming package manifest (optional):

```powershell
.\scripts\Export-DeploymentFileManifest.ps1 -SourcePath 'C:\staging\pkg' -ManifestPath 'C:\deploy\reports\incoming-manifest.json' -IncludePatterns '*'
```

4. Run a pre-deployment drift check:

```powershell
.\scripts\Test-DeploymentDrift.ps1 -ApplicationName 'MyApp' -EnvironmentName 'Prod' \
    -RootPath 'C:\inetpub\wwwroot' -BaselinePath 'C:\deploy\baseline\last-successful-deployment.json' \
    -IncomingPackagePath 'C:\staging\pkg' -ReportPath 'C:\deploy\reports' -IncludePatterns '*'
```

Exit codes
- `0` — No drift
- `1` — Drift detected (and `-FailOnDrift` behavior)
- `2` — Script error
- `3` — Baseline missing (deployment-zero)

Testing

Run the Pester tests (uses external `powershell -File` calls so scripts are non-interactive):

```powershell
Import-Module Pester
Invoke-Pester -Script .\tests\DeploymentDrift.Tests.ps1
```

Notes
- Designed for Windows PowerShell 5.1 compatibility. Avoid PowerShell Core-only flags.
- Scripts import the module manifest first (`DeploymentDrift.Common.psd1`) and fall back to the `.psm1`.
- The module is imported with `-Scope Local` in the scripts to avoid polluting the global session.

If you want, I can add a short CONTRIBUTING or CI workflow to run tests on push/PR.
# BrainDrift — Windows Deployment Drift Detection

Resumen rápido
- Scripts PowerShell para detectar "drift" en servidores Windows usando un modelo de tres vías:
  - A = baseline (última implementación oficial).
  - B = estado actual del servidor.
  - C = paquete entrante (opcional).

Contenido principal
- `Test-DeploymentDrift.ps1` — chequeo pre-despliegue (genera reporte JSON).
- `New-DeploymentBaseline.ps1` — crea/actualiza la baseline tras un despliegue exitoso.
- `Export-DeploymentFileManifest.ps1` — genera manifiesto/manifest desde carpeta de paquete.
- `src/DeploymentDrift.Common.psm1` — módulo con helpers (hashing, JSON, comparación).
- `config/deployment-drift.config.json` — ejemplo de configuración.
- `docs/` — documentación y ejemplos de uso.

Quick start (línea de comandos)

1) Ejecutar el chequeo pre-despliegue:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-DeploymentDrift.ps1 \
  -ApplicationName 'MyApp' -EnvironmentName 'QA' \
  -RootPath 'C:\inetpub\MyApp' \
  -BaselinePath 'C:\Deployments\MyApp\baseline\last-successful-deployment.json' \
  -ReportPath 'C:\Deployments\MyApp\reports' \
  -IncludePatterns 'web.config','*.config','*.json','*.xml','*.dll' \
  -ExcludePatterns 'logs*','temp*','App_Data\\cache*'
```

2) Crear la baseline inicial (solo cuando se valida manualmente el servidor):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-DeploymentBaseline.ps1 \
  -ApplicationName 'MyApp' -DeploymentId 'INIT-<timestamp>' -EnvironmentName 'QA' \
  -ServerName $env:COMPUTERNAME -RootPath 'C:\inetpub\MyApp' \
  -BaselinePath 'C:\Deployments\MyApp\baseline\last-successful-deployment.json' \
  -IncludePatterns '*' -ExcludePatterns 'logs*','temp*','App_Data\\cache*'
```

3) Exportar manifiesto del paquete entrante:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Export-DeploymentFileManifest.ps1 \
  -SourcePath 'C:\Deployments\MyApp\incoming' \
  -ManifestPath 'C:\Deployments\MyApp\manifests\incoming-manifest.json' \
  -IncludePatterns 'web.config','*.config','*.json','*.xml','*.dll'
```

Salida y comportamiento
- Los scripts generan/reportan en JSON y usan códigos de salida para automatización:
  - `0` = Sin drift.
  - `1` = Drift detectado y `-FailOnDrift` habilitado (fallo para pipelines).
  - `2` = Error del script.
  - `3` = Baseline faltante (deployment-zero — requiere bootstrap manual).

Convenciones de archivos
- Baseline (JSON): contiene `metadata` y `files[]` con `relativePath`, `fullPath`, `hash`, `fileSize`, `lastWriteTimeUtc`, `hashAlgorithm`.
- Reporte (JSON): `metadata`, `summary`, `classification`, `files[]` con `classification` por archivo y `recommendedAction`.

Integración en Harness (sugerencia)
- Paso pre-despliegue: ejecutar `scripts\\Test-DeploymentDrift.ps1`. Si devuelve `1` o `3`, pausar y pedir aprobación manual.
- Paso post-despliegue: si todo OK, ejecutar `scripts\\New-DeploymentBaseline.ps1` para actualizar la baseline.

Notas operativas
- Protege la carpeta donde guardas las baselines con permisos NTFS (no editar manualmente).
- Empieza incluyendo solo archivos críticos (configuraciones, `web.config`, `appsettings.json`), luego expande la lista.
- No actualices la baseline si el despliegue falló.

Soporte
- Docs y ejemplos están en la carpeta `docs/`.
- Archivo de ejemplo de configuración: `config/deployment-drift.config.json`.

Si quieres, actualizo este README con más detalles concretos de `Architect` (rutas, ejemplos de Harness) ahora.

