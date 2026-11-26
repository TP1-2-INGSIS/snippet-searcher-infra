# Decisiones de diseño (ADR)

Resumen de las decisiones transversales de la plataforma. Las decisiones internas de Snippets (formato de error, 404 vs 403, etc.) están en el `docs/design-decisions.md` de ese repo. Todas las decisiones de esta página están tomadas.

## Decisiones transversales

### T1 · El JWT se valida solo en Snippets
- **Contexto:** nginx solo expone `/api/`, que va a Snippets. Los demás servicios no son alcanzables desde afuera.
- **Opciones:** validar en cada servicio, o validar en Snippets y confiar en la red interna.
- **Decisión:** Snippets valida el JWT de Auth0 (firma, issuer y audience). Permissions, Language y Assets quedan internos.
- **Consecuencias:** una sola configuración de seguridad. La red del stack es parte del modelo de confianza.

### T2 · `X-User-Id` solo con un flag
- **Contexto:** los tests, el entorno local y el e2e no tienen Auth0.
- **Decisión:** el header `X-User-Id` (y `?userId=` en el WebSocket) solo se acepta con `AUTH_HEADER_IDENTITY_ENABLED=true`. Por defecto es `false` y nunca se activa en prod.
- **Consecuencias:** los tests siguen siendo simples y prod no acepta identidades sin firma.

### T3 · Usuarios en Auth0, no en Permissions
- **Contexto:** Permissions tenía registro y login propios con BCrypt.
- **Decisión (ya en `main`):** `GET /users?search=&limit=` de Permissions busca en la Management API de Auth0 (`GET /api/v2/users`). Se eliminaron `/auth/register`, `/auth/login`, la entidad `User` y BCrypt. Los permisos guardan `user_id` como string sin FK, así que el `sub` de Auth0 sirve tal cual. Se elige con `USERS_PROVIDER`: `auth0` busca en Auth0; `none` (el default) devuelve una lista vacía y avisa al arrancar. Con `auth0` hacen falta `AUTH0_DOMAIN`, `AUTH0_MGMT_CLIENT_ID` y `AUTH0_MGMT_CLIENT_SECRET`, y el servicio no arranca si falta alguna. Si Auth0 falla, responde 502 `USERS_PROVIDER_ERROR`.
- **Consecuencias:** hace falta una app Machine to Machine con scope `read:users` y sus credenciales en el `.env` de la VM.

### T4 · Contenido original y formateado por separado
- **Contexto:** el formateo automático pisaba el código del usuario, lo que choca con la descarga de la versión original (US13).
- **Decisión:** `content` es lo que escribió el usuario y `formatted_content` guarda el derivado. Si el usuario edita, se recalcula.
- **Consecuencias:** una columna más. El original nunca se pierde.

### T5 · El estado de las tareas vive en la base de Snippets
- **Contexto:** Redis es un transporte y puede perder o duplicar mensajes.
- **Decisión:** una fila de estado por snippet (el patrón de la clase de procesamiento asíncrono): responde 202, procesa aparte y re-encola las tareas colgadas. El `contentHash` evita aplicar un resultado viejo.
- **Consecuencias:** la UI consulta el listado y ve `pending`. Redis se puede vaciar sin perder información.

### T6 · Los eventos llevan el contenido
- **Decisión:** los eventos de Redis incluyen el contenido del snippet (son chicos), así que el worker no necesita leer de Assets.
- **Consecuencias:** los workers no dependen de Assets. Los mensajes son más grandes.

### T7 · Revalidación por `engineVersion`
- **Estado:** en implementación (SNIP-6). `engineVersion` en `GET /languages` ya está en Language.
- **Decisión:** Language informa la versión de su motor (la del artefacto CNC) en `GET /languages`. Snippets la compara al arrancar y periódicamente (intervalo configurable); si cambió, re-encola validación y lint de los snippets del lenguaje.
- **Consecuencias:** cumple "con cada versión nueva del parser se re-evalúan todos los snippets", sin depender de un aviso externo.

### T8 · US16 sigue sincrónico
- **Decisión:** al editar, los tests corren después de guardar y su resultado no modifica el update.
- **Consecuencias:** cumple la nota de la US16 sin sumar un flujo asíncrono más.

## Decisiones D1 a D5

### D1 · Procesamiento asíncrono con workers de Language
- **Contexto:** lint y formato masivos (US12, US15) y la revalidación pueden ser largos y deben tolerar fallas.
- **Opciones:** (A) Snippets publica en `tasks:printscript` y workers de Language procesan y publican en `tasks:results`; (B) Snippets encola y consume él mismo, llamando a Language por REST.
- **Decisión:** A. Los workers son la misma imagen de Language con `APP_MODE=worker` y N réplicas.
- **Consecuencias:** más piezas (Redis y workers) pero se reusa el worker existente, se escala por réplicas y un snippet que falla tres veces queda en `FAILED` sin frenar al resto.

### D2 · Ejecución interactiva por WebSocket
- **Contexto:** la US10 pide dar inputs a medida que se piden y ver los outputs a medida que se imprimen.
- **Opciones:** (A) WebSocket UI, Snippets y Language; (B) HTTP "replay", re-ejecutando con los inputs acumulados.
- **Decisión:** A. Snippets valida token y permiso y hace de relay. nginx ya tenía los headers de `Upgrade`.
- **Consecuencias:** es streaming real, a costa de manejar sesiones, timeouts (60 s por input, 5 min en total) y códigos de cierre. B queda como plan de contingencia.

### D3 · Assets con Azure Blob Storage
- **Contexto:** el diseño original tenía un servicio de assets para el contenido, que nadie llamaba.
- **Opciones:** (A) integrarlo con Azure Blob en prod y Azurite en dev y e2e; (A') Azurite también en prod; (B) no usarlo y guardar el contenido en Postgres.
- **Decisión:** A. Snippets guarda la metadata y Assets el contenido.
- **Consecuencias:** una dependencia más y una storage account en Azure. Dev y e2e funcionan sin credenciales reales.

### D4 · Branching dev y main
- **Contexto:** la consigna de infraestructura pide ambientes separados.
- **Opciones:** (A) seguir con `main` al principio y pasar a `dev` al tener el ambiente, con un release `dev` a `main` por ola; (B) todo a `dev` desde el inicio.
- **Decisión:** A.
- **Consecuencias:** `dev` despliega a la VM dev y `main` a la de prod. Los tags de imagen distinguen el ambiente (`:dev`, `:latest`).

### D5 · Dos VMs, una por ambiente
- **Contexto:** hay que tener dev y prod, cada uno con la base, Redis, los workers y los servicios.
- **Opciones:** (A) una VM por ambiente; (B) una VM con dos stacks.
- **Decisión:** A.
- **Consecuencias:** cuesta más pero aísla los ambientes y evita quedarse sin RAM con dos copias de todo. Cada VM es su propio Swarm con el stack `snippet-searcher` y su subdominio DuckDNS.
