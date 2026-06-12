# Testing the Empatia API in Postman

Base URL:
```
https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1
```

## 1. Get your API Key

After applying the Terraform module, get the key value:

```bash
terraform output -raw api_key_value
```

Or in AWS Console: **API Gateway → API Keys → (your key) → Show**

## 2. Create a Postman request

**Method:** `POST`
**URL (details):**
```
https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1/empatia/details/events
```
**URL (summary):**
```
https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1/empatia/summary/events
```

## 3. Headers tab

| Key | Value |
|---|---|
| `x-api-key` | `<your API key value>` |
| `Content-Type` | `application/json` |

## 4. Body tab

Select **raw** → **JSON**, then paste:

### For `/empatia/details/events`
```json
{
    "tenant_id": "empatia",
    "conversacion_id": "conv_0001",
    "tipo_documento": "CC",
    "numero_documento": "1234567890",
    "numero_telefono": "3001234567",
    "tipo_producto": "credito",
    "tipo": "conversacion",
    "fecha_creacion": "2026-06-12T10:00:00Z",
    "data": {
        "conversacion": "Cliente: Hola, tengo una duda sobre mi factura.\nAgente: Claro, dime en qué te ayudo."
    }
}
```

### For `/empatia/summary/events`
```json
{
    "tenant_id": "empatia",
    "conversacion_id": "conv_0001",
    "tipo_documento": "CC",
    "numero_documento": "1234567890",
    "numero_telefono": "3001234567",
    "tipo_producto": "credito",
    "tipo": "resumen",
    "fecha_creacion": "2026-06-12T10:05:00Z",
    "data": {
        "motivo": "Consulta de factura",
        "resumen": "El cliente preguntó por su factura y se le explicó el detalle de cobros."
    }
}
```

## 5. Send and check the response

### ✅ Success — `202 Accepted`
```json
{
    "message": "Transcript received successfully.",
    "record_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "endpoint": "details",
    "s3_key": "transcripts/details/2026/06/12/f47ac10b-....json"
}
```

### ❌ Missing field — `400 Bad Request`
```json
{
    "error": "Missing required fields: ['fecha_creacion']"
}
```

### ❌ Wrong `tipo` value — `400 Bad Request`
```json
{
    "error": "Field 'tipo' must be 'conversacion' for /details/events."
}
```

### ❌ Missing API key — `403 Forbidden`
```json
{
    "message": "Forbidden"
}
```
> This response comes from API Gateway itself (before reaching the Lambda) — check the `x-api-key` header is set correctly.

### ❌ Wrong endpoint — `404 Not Found`
```json
{
    "error": "Endpoint '/empatia/wrong/events' not found."
}
```

## 6. Quick test checklist

- [ ] POST `/empatia/details/events` with valid body → expect `202`
- [ ] POST `/empatia/summary/events` with valid body → expect `202`
- [ ] Send without `x-api-key` header → expect `403`
- [ ] Send with wrong `x-api-key` → expect `403`
- [ ] Send malformed JSON (e.g. trailing comma) → expect `400` "Invalid JSON"
- [ ] Send `/details/events` body but with `"tipo": "resumen"` → expect `400`
- [ ] Remove `data.conversacion` from a details payload → expect `400`
- [ ] Send `GET` instead of `POST` → expect `405` or `403` (API Gateway may block first since method isn't defined)
- [ ] Check S3 landing bucket — confirm a `.json` file appears under `transcripts/details/<date>/...`
- [ ] Check SQS queue — confirm message count increases / message visible in "Send and receive messages"

## 7. (Optional) Save as a Postman Collection

You can create a **Collection** called `Empatia API` with:
- A **Collection-level variable** `base_url` = `https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1`
- A **Collection-level variable** `api_key` = `<your key>`
- A **Collection-level header**: `x-api-key: {{api_key}}` (so you don't repeat it per request)
- Two requests:
  - `POST {{base_url}}/empatia/details/events`
  - `POST {{base_url}}/empatia/summary/events`

This way, if the API key rotates, you only update it in one place.
