# User stories y cómo las cubre el sistema

Fuente: "Snippet Searcher - Casos de uso" (US1 a US16). Las rutas son las de Snippets, que es la única puerta de la UI (nginx las expone bajo `/api`). "En implementación" marca lo que está en PRs abiertos o por abrirse al cerrar este documento.

| US | Título | Cómo la cubre el sistema |
|---|---|---|
| 1 | Crear snippet mediante archivo | Snippets `POST /snippets/upload`. Valida con Language (`/languages/{lang}/validate`); si es inválido responde 422 con `{rule, message, line, column}`. Guarda el contenido en Assets. Validación con el motor real: en implementación. Ver [secuencia (a)](secuencias.md#a-crear-un-snippet-con-validación). |
| 2 | Actualizar snippet mediante archivo | Snippets `PUT /snippets/{id}/upload`, con la misma validación y el mismo 422. Permiso de escritura consultado a Permissions. |
| 3 | Crear snippet en editor | Snippets `POST /snippets`, mismas reglas que la US1. |
| 4 | Actualizar snippet en editor | Snippets `PUT /snippets/{id}`, mismas reglas que la US2. |
| 5 | Visualizar todos los snippets | Snippets `GET /snippets` con filtros por relación (autor, compartido o ambos), nombre, lenguaje y validez, y orden por esos campos. Muestra el estado de lint; el estado `pending` de las tareas asíncronas: en implementación. |
| 6 | Visualizar un snippet | Snippets `GET /snippets/{id}` (datos, contenido y reglas incumplidas) y `GET /snippets/{id}/tests`. |
| 7 | Compartir snippet | Snippets `GET /users` (proxy a Permissions, que busca en la Management API de Auth0) y `POST /snippets/{id}/share`. Permiso de lectura sobre el snippet y sus tests. Buscador con usuarios de Auth0: en implementación. Ver [secuencia (b)](secuencias.md#b-compartir-con-búsqueda-de-usuarios-de-auth0). |
| 8 | Crear tests | Snippets `POST /snippets/{id}/tests`, `GET`, `PUT` y `DELETE /snippets/{id}/tests/{testId}`. Inputs y outputs ordenados; se aceptan tests que no pasan. |
| 9 | Correr tests | Snippets `POST /snippets/{id}/tests/{testId}/run`, que llama a Language `/languages/{lang}/test`. Se corre uno a la vez. Mostrar el output en la UI: en implementación. Ver [secuencia (e)](secuencias.md#e-correr-un-test). |
| 10 | Ejecución interactiva | WebSocket `wss://<host>/api/snippets/{id}/run`, con relay de Snippets hacia Language `/languages/{lang}/run`. Mensajes `input-request`, `input`, `output`, `finished` y `error`. En implementación. Ver [secuencia (d)](secuencias.md#d-ejecución-interactiva-por-websocket). |
| 11 | Habilitar reglas de formateo | Snippets `GET` y `PUT /rules/{language}/format`. Reglas por defecto de PrintScript; se habilitan y deshabilitan. |
| 12 | Formateo automático | `PUT /rules/{language}/format` responde 202 y encola una tarea `FORMAT` por snippet en Redis Streams; los workers de Language procesan. Tolerante a fallos: reintentos y salto del snippet que falla (`FAILED`). El resultado va a `formatted_content`. En implementación. Ver [secuencia (c)](secuencias.md#c-aplicar-reglas-de-forma-asíncrona-lint-y-formato). |
| 13 | Descarga | Snippets `GET /snippets/{id}/download`, versión original (`content`) o formateada (`formatted_content`). Que el formateo no pise el original: en implementación. |
| 14 | Habilitar reglas de linting | Snippets `GET` y `PUT /rules/{language}/lint`, con las reglas por defecto de PrintScript. |
| 15 | Linting automático | `PUT /rules/{language}/lint` responde 202 y encola tareas `LINT`; mismo mecanismo y tolerancia a fallos que la US12. En implementación. |
| 16 | Testing automático | Al editar, Snippets corre todos los tests del snippet de forma sincrónica después de guardar; el resultado no modifica el update. |

## Requisitos transversales de la consigna

| Requisito | Cómo se cumple |
|---|---|
| Usuarios autenticados | Auth0 (login en la UI) y validación del JWT en Snippets. En implementación. |
| Re-evaluar todos los snippets con cada versión nueva del parser | Comparación de `engineVersion` y re-encolado. En implementación. Ver [secuencia (f)](secuencias.md#f-revalidación-cuando-cambia-la-versión-del-parser). |
| Otros lenguajes en el futuro | Language expone `/languages/{lang}/...` y `GET /languages`; Snippets no conoce el motor. |
