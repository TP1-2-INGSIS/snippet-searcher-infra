# Diagramas de secuencia

Los flujos más importantes de la plataforma. Los endpoints y mensajes son los del contrato fijado entre repos (ver [decisiones.md](decisiones.md)). Todo request a Snippets pasa antes por nginx (`/api/` → Snippets) y lleva el JWT de Auth0; para no repetirlo, los diagramas arrancan en Snippets.

## (a) Crear un snippet con validación

El usuario crea el snippet (por editor, `POST /snippets`, o por archivo, `POST /snippets/upload`). Snippets valida el código con Language, lo lintea para fijar `lint_status`, lo guarda y registra al owner en Permissions. Si es inválido, responde 422 con la regla, la línea y la columna. Si falla el alta del permiso, borra el snippet (compensación). Hoy el contenido se guarda en Postgres; pasarlo a Assets está en implementación (SNIP-4).

```mermaid
sequenceDiagram
    actor U as Usuario
    participant UI as UI
    participant S as Snippets
    participant L as Language
    participant A as Assets
    participant P as Permissions

    U->>UI: nombre, descripción, lenguaje, versión, código
    UI->>S: POST /api/snippets (JWT)
    S->>S: valida el JWT y extrae el sub
    S->>L: POST /languages/{lang}/validate
    alt código inválido
        L-->>S: errors [{rule, message, line, column}]
        S-->>UI: 422 INVALID_SNIPPET con details
        UI-->>U: muestra regla, línea y columna
    else código válido
        L-->>S: ok
        S->>L: POST /languages/{lang}/lint (reglas del usuario)
        L-->>S: violaciones
        S->>S: fija lint_status (COMPLIANT o NON_COMPLIANT)
        S->>S: guarda el snippet (contenido en Postgres)
        opt en implementación (SNIP-4)
            S->>A: POST /v1/assets/{snippetId} (contenido en Assets)
            A-->>S: 201
        end
        S->>P: POST /permissions (OWNER)
        alt falla el alta del permiso
            P-->>S: error
            S->>S: borra el snippet (compensación)
            S-->>UI: 502 DOWNSTREAM_ERROR
        else ok
            P-->>S: 201
            S-->>UI: 201 con el snippet
            UI-->>U: snippet creado
        end
    end
```

## (b) Compartir con búsqueda de usuarios de Auth0

Mientras el usuario escribe (con debounce de 300 ms), la UI busca usuarios. Permissions los consulta en la Management API de Auth0. Al elegir uno, Snippets verifica con `/permissions/check` que quien comparte sea `OWNER` y registra un permiso `READ` con `POST /permissions`.

```mermaid
sequenceDiagram
    actor U as Owner
    participant UI as UI
    participant S as Snippets
    participant P as Permissions
    participant Au as Auth0 Management API

    U->>UI: escribe "ma" en el buscador
    UI->>S: GET /api/users?search=ma
    S->>P: GET /users?search=ma
    P->>Au: GET /api/v2/users?q=ma (token M2M)
    Au-->>P: usuarios (user_id, nombre, email)
    P-->>S: lista de usuarios
    S-->>UI: lista de usuarios
    UI-->>U: muestra nombre y email

    U->>UI: elige un usuario y confirma
    UI->>S: POST /api/snippets/{id}/share {userId}
    S->>P: GET /permissions/check?userId&snippetId&action=SHARE
    P-->>S: allowed (es owner)
    S->>P: POST /permissions {snippetId, userId, role READ}
    alt ya estaba compartido
        P-->>S: 409
        S-->>UI: 409 ALREADY_SHARED
    else nuevo
        P-->>S: 201
        S-->>UI: 204
    end
```

## (c) Aplicar reglas de forma asíncrona (lint y formato)

`PUT /rules/{language}/lint` (o `/format`) guarda las reglas, deja una fila de estado por snippet y publica una tarea por snippet. Responde 202 sin esperar. Los workers de Language procesan y publican resultados; Snippets los consume y actualiza el estado. La UI consulta el listado y ve `pending` hasta que llega el resultado.

```mermaid
sequenceDiagram
    actor U as Admin
    participant UI as UI
    participant S as Snippets
    participant DB as snippets-db
    participant R as Redis Streams
    participant W as Language worker
    participant C as Consumidor de resultados (Snippets)

    U->>UI: habilita o deshabilita reglas
    UI->>S: PUT /api/rules/{lang}/lint
    S->>DB: guarda reglas, marca los snippets en PENDING
    loop un evento por snippet
        S->>R: XADD tasks:printscript (TaskEvent LINT, contentHash)
    end
    S-->>UI: 202 Accepted
    UI->>S: GET /api/snippets (polling)
    S-->>UI: estado pending

    R->>W: XREADGROUP (tasks:printscript)
    W->>W: corre el motor sobre el contenido
    alt la tarea se procesa
        W->>R: XADD tasks:results (status OK, errors)
        W->>R: XACK
    else el código no parsea
        W->>R: XADD tasks:results (status INVALID_SOURCE, errors)
        W->>R: XACK
    else falla el worker (excepción o caída)
        Note over W,R: no hay ACK, la tarea queda pendiente
        R->>W: re-entrega (XPENDING + XCLAIM, intento 2 y 3)
        opt se agotan los 3 intentos (REDIS_MAX_ATTEMPTS)
            W->>R: XADD tasks:results (status FAILED, errorMessage)
            W->>R: XACK
        end
    end

    R->>C: XREADGROUP (tasks:results, con XAUTOCLAIM de lo pendiente)
    C->>DB: actualiza el estado si el contentHash coincide
    Note over C,DB: en lint, OK sin errores = COMPLIANT y OK con errores = NON_COMPLIANT, en format OK = DONE, INVALID_SOURCE o FAILED = FAILED
    UI->>S: GET /api/snippets (polling)
    S-->>UI: estado final (compliant, non-compliant o failed)

    opt tareas colgadas
        S->>R: re-encola las tareas PENDING vencidas
    end
```

El proceso es tolerante a fallos: un snippet que falla tres veces queda en `FAILED` y el resto sigue, así que no se frena el lote. Si el contenido cambió mientras la tarea estaba en vuelo, el `contentHash` no coincide y el resultado se descarta.

## (d) Ejecución interactiva por WebSocket

La UI abre un WebSocket contra Snippets, que valida el token y el permiso y abre otro hacia Language. Snippets reenvía los mensajes en ambos sentidos. El intérprete se queda esperando cuando pide un input y cada `println` se manda al instante.

```mermaid
sequenceDiagram
    actor U as Usuario
    participant UI as UI
    participant S as Snippets (relay)
    participant P as Permissions
    participant L as Language

    U->>UI: Run
    UI->>S: WSS /api/snippets/{id}/run?access_token=JWT
    S->>S: valida el JWT
    S->>P: GET /permissions/check?userId&snippetId&action=READ
    alt sin autenticación o sin permiso
        S-->>UI: cierre 1008
    else autorizado
        S->>L: WS /languages/{lang}/run
        S->>L: {type: start, content, version}
        L-->>S: {type: output, value}
        S-->>UI: {type: output, value}
        L-->>S: {type: input-request, prompt}
        S-->>UI: {type: input-request, prompt}
        UI-->>U: muestra el prompt
        U->>UI: escribe el valor
        UI->>S: {type: input, value}
        S->>L: {type: input, value}
        L-->>S: {type: output, value}
        S-->>UI: {type: output, value}
        alt termina bien
            L-->>S: {type: finished}
            S-->>UI: {type: finished}
            S-->>UI: cierre 1000
        else error de sintaxis, de runtime o timeout de input (60 s)
            L-->>S: {type: error, message, line, column}
            S-->>UI: {type: error, message, line, column}
            L-->>S: cierre 1000
            S-->>UI: cierre 1000 (reenvía el código de Language)
        else Language no responde, se cae o vence el idle del relay
            S-->>UI: {type: error, message}
            S-->>UI: cierre 1011
        else el usuario corta
            UI->>S: {type: stop}
            S->>L: {type: stop}
            S-->>UI: cierre 1000
        end
    end
```

Códigos de cierre de Language: 1000 para `finished`, `stop`, errores del programa y timeout de input; 1008 para violaciones del protocolo y si no llega `start` a los 10 s; 1011 para "busy", el límite de 5 minutos y errores internos. El relay reenvía el código de Language, usa 1008 para sus propias fallas de autenticación o permiso, y manda `error` más 1011 si Language no responde, se corta o vence su idle.

## (e) Correr un test

El test (inputs y outputs esperados) vive en Snippets. Para correrlo, Snippets le pide a Language que ejecute el snippet con esos inputs y compara los outputs en orden. Se corre un test a la vez.

```mermaid
sequenceDiagram
    actor U as Usuario
    participant UI as UI
    participant S as Snippets
    participant P as Permissions
    participant A as Assets
    participant L as Language

    U->>UI: Run test
    UI->>S: POST /api/snippets/{id}/tests/{testId}/run
    S->>P: GET /permissions/check?userId&snippetId&action=READ
    P-->>S: allowed
    S->>A: GET /v1/assets/{snippetId}
    A-->>S: contenido
    S->>L: POST /languages/{lang}/test {content, version, inputs, expectedOutputs}
    L->>L: ejecuta y compara los println en orden
    L-->>S: {passed, outputs, errorMessage}
    S-->>UI: 200 {passed, outputs}
    UI-->>U: muestra el output y Pass o Fail
```

Al editar un snippet, Snippets corre todos sus tests de forma sincrónica después de guardar. El resultado de los tests no modifica el update (US16).

## (f) Revalidación cuando cambia la versión del parser

Estado: en implementación (SNIP-6).

Language informa la versión de su motor (`engineVersion`) en `GET /languages`. Snippets la compara al arrancar y periódicamente, con un intervalo configurable. Si cambió, vuelve a encolar validación y lint de todos los snippets de ese lenguaje por el mismo mecanismo asíncrono del diagrama (c).

```mermaid
sequenceDiagram
    participant J as Scheduler de Snippets
    participant L as Language
    participant DB as snippets-db
    participant R as Redis Streams
    participant W as Language workers

    Note over J: al arrancar y cada intervalo configurable
    J->>L: GET /languages
    L-->>J: [{id, versions, engineVersion}]
    J->>DB: lee la engineVersion guardada
    alt cambió la engineVersion
        J->>DB: guarda la nueva, marca los snippets del lenguaje en PENDING
        loop por cada snippet del lenguaje
            J->>R: XADD tasks:printscript (VALIDATE y LINT)
        end
        R->>W: tareas
        W->>R: XADD tasks:results
        Note over R,DB: el consumidor actualiza validez y lint (ver diagrama c)
    else igual
        J->>J: no hace nada
    end
```
