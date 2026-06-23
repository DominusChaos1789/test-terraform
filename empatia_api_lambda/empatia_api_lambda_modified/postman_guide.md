# Empatia API — Postman Guide

A step-by-step guide to testing the Empatia Transcripts API in Postman,
including the OAuth2 (Cognito) authentication flow.

---

## 1. Import the collection

1. Open Postman.
2. Click **Import** (top-left).
3. Drag in `empatia_api.postman_collection.json` (or browse to it).
4. A collection named **"Empatia Transcripts API"** appears in the left sidebar
   with folders: **Auth**, **Details**, **Summary**, **Auth Errors**.

---

## 2. Set the collection variables

Click the collection name → **Variables** tab. Fill in the **Current value**
column (leave the others as-is):

| Variable        | What to put                                                                 |
|-----------------|------------------------------------------------------------------------------|
| `base_url`      | `https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1` (already set) |
| `token_url`     | Your Cognito token endpoint (see below)                                      |
| `client_id`     | From `terraform output client_id`                                            |
| `client_secret` | From `terraform output -raw client_secret`                                   |
| `access_token`  | Leave blank — filled automatically in step 3                                 |

**Where the token_url comes from:**
```
https://<cognito_domain_prefix>.auth.us-east-2.amazoncognito.com/oauth2/token
```
e.g. `https://empatia-augusta-nexa-dev.auth.us-east-2.amazoncognito.com/oauth2/token`

Or just run:
```bash
terraform output token_url
```

Click **Save** (Ctrl/Cmd + S) after filling these in.

---

## 3. Get an access token

The API uses OAuth2 **Client Credentials** — a machine-to-machine flow. You
exchange your client_id + client_secret for a short-lived Bearer token, then
send that token on every request.

1. Open the **Auth** folder → **Get OAuth2 Token (Client Credentials)**.
2. Click **Send**.
3. You should get a `200 OK` with a body like:
   ```json
   {
     "access_token": "eyJraWQiOi...",
     "expires_in": 3600,
     "token_type": "Bearer"
   }
   ```
4. The request's **Tests** script automatically saves `access_token` into the
   collection variable — you don't need to copy/paste anything.

> The token expires (default 1 hour). When you start getting `401`s, just
> re-run this request to refresh it.

**How the auth is wired:** the collection has a **collection-level Bearer
auth** set to `{{access_token}}`. Every request inherits it, so once the token
is saved, all Details/Summary requests are authenticated automatically.

---

## 4. Send a Details request

1. Open **Details** → **POST Details - Valid (Natural)**.
2. Check the **Body** tab — it's set to **raw / JSON** with a sample payload:
   ```json
   {
     "tenant_id": "empatia",
     "idLlamada": "call_0001",
     "tipoPersona": "Natural",
     "tipoIdentificacion": "CC",
     "numeroIdentificacion": "1234567890",
     "primerNombre": "Juan",
     "primerApellido": "Perez",
     "codigoTipificacion": "TIP001",
     "descripcionTipificacion": "Consulta general",
     "fechaInicio": "2026-06-21T10:00:00Z",
     "data": {
       "conversacion": "Cliente: Hola...\nAgente: Hola, en que te ayudo?"
     }
   }
   ```
3. Click **Send**.
4. Expected `202 Accepted`:
   ```json
   {
     "message": "Transcript received successfully.",
     "record_id": "f47ac10b-...",
     "endpoint": "details",
     "s3_key": "empatia/transcripciones/detalle/api/year=2026/month=06/day=21/f47ac10b-....json"
   }
   ```

---

## 5. Send a Summary request

Same idea, in the **Summary** folder. The body differs only in the `data`
object:
```json
"data": {
  "motivo": "Consulta de factura",
  "resumen": "El cliente pregunto por su factura y se le explico el detalle."
}
```

---

## 6. Understand the field rules

The API validates the payload. Key rules:

- **Always required:** `tenant_id`, `tipoPersona`, `tipoIdentificacion`,
  `numeroIdentificacion`, `codigoTipificacion`, `data`
- **`tipoPersona`** must be exactly `"Natural"` or `"Juridica"`
- **If `tipoPersona = "Natural"`** → `primerNombre` and `primerApellido` required
- **If `tipoPersona = "Juridica"`** → `razonSocial` required
- **`/details` →** `data.conversacion` required
- **`/summary` →** `data.motivo` and `data.resumen` required

The collection includes pre-built requests that deliberately break each rule
(in the Details/Summary folders) so you can see the `400` error messages.

---

## 7. Run the whole collection at once

To test everything in one go:

1. Click the collection → **Run** (or the **Runner** icon).
2. Make sure **Get OAuth2 Token** is first in the run order (it is by default).
3. Click **Run Empatia Transcripts API**.
4. Postman executes every request and shows a pass/fail report based on the
   built-in **Tests** scripts (status codes, response fields, S3 path format).

This is handy after every Terraform deploy or Lambda update to confirm nothing
broke.

---

## 8. Troubleshooting

| Symptom                                            | Likely cause / fix                                                                 |
|----------------------------------------------------|-------------------------------------------------------------------------------------|
| `401 Unauthorized`                                 | Token missing or expired → re-run **Get OAuth2 Token**                              |
| `403 Forbidden`                                    | Token valid but missing the `transcripts:write` scope → check the App Client scopes |
| Token request returns `400 invalid_client`         | Wrong `client_id`/`client_secret`, or client secret not enabled                     |
| Token request returns `400 invalid_scope`          | Scope string doesn't match the resource server identifier in Cognito               |
| Token request `404` / DNS error                    | `token_url` wrong, or Cognito domain not created yet                                |
| `202` but nothing in S3                            | Check Lambda CloudWatch logs; S3 write failure is non-fatal and logged              |
| `SendMessageResponse` XML in the body              | API Gateway is integrated directly to SQS, not Lambda → see migration_steps.md      |
| `413 Request body too large`                       | Payload over 256 KB → trim the transcript or raise MAX_BODY_BYTES in the handler    |
| `400 Invalid JSON`                                 | Malformed body (trailing comma, unquoted key, etc.)                                |

---

## 9. Getting a token outside Postman (curl)

For reference, the same token exchange via curl:

```bash
curl -X POST https://empatia-augusta-nexa-dev.auth.us-east-2.amazoncognito.com/oauth2/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=YOUR_CLIENT_ID" \
  -d "client_secret=YOUR_CLIENT_SECRET" \
  -d "scope=https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1/transcripts:write"
```

Then call the API with the returned token:

```bash
curl -X POST https://ba5xmxdwoh.execute-api.us-east-2.amazonaws.com/dev-1/empatia/details/events \
  -H "Authorization: Bearer THE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ ... payload ... }'
```
